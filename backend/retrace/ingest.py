"""Multipart session ingestion with strict manifest, reference, path and size checks."""

from __future__ import annotations

import asyncio
import hashlib
import shutil
from dataclasses import dataclass
from urllib.parse import urlsplit

from pydantic import ValidationError
from starlette.datastructures import UploadFile
from starlette.requests import Request

from .authstore import Device
from .config import Settings
from .errors import ApiError
from .models import SAFE_FILENAME, Manifest
from .redaction import redact_network_entry
from .security import iso, utcnow
from .state.base import EvidenceRefRec, SessionRec, SharedState
from .storage import ArtifactStore

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_MAGIC = b"\xff\xd8\xff"
CHUNK = 64 * 1024


@dataclass
class IngestResult:
    session: SessionRec
    server_redactions: int
    duplicate: bool = False


_session_locks: dict[str, asyncio.Lock] = {}


def _lock_for(session_id: str) -> asyncio.Lock:
    if len(_session_locks) > 1000:
        for k in [k for k, v in _session_locks.items() if not v.locked()]:
            del _session_locks[k]
    return _session_locks.setdefault(session_id, asyncio.Lock())


def session_records(manifest: Manifest, device_id: str, store: ArtifactStore) -> tuple[SessionRec, list[EvidenceRefRec]]:
    """Shared-state records for an already sanitized manifest."""
    rec = SessionRec(
        session_id=str(manifest.id),
        project_id=manifest.project_id,
        status="uploaded",
        app_name=manifest.app.name,
        bundle_id=manifest.app.bundle_id,
        task=manifest.task,
        started_at=iso(manifest.started_at),
        duration_ms=manifest.duration_ms,
        frame_count=len(manifest.frames),
        interaction_count=len(manifest.interactions),
        network_count=len(manifest.network),
        network_status=manifest.network_status,
        uploaded_at=iso(utcnow()),
        uploaded_by_device=device_id,
    )
    refs = [
        EvidenceRefRec(str(f.id), "frame", f.timestamp_ms, store.frame_relpath(str(f.id), _ext(f.filename)), f"{f.width}x{f.height} frame")
        for f in manifest.frames
    ]
    refs += [EvidenceRefRec(str(i.id), "interaction", i.timestamp_ms, None, _summary_interaction(i)) for i in manifest.interactions]
    for n in manifest.network:
        path = urlsplit(n.url).path or "/"
        refs.append(EvidenceRefRec(str(n.id), "network", n.timestamp_ms, None, f"{n.method.upper()} {path} {n.status or ''}".strip()[:200]))
    return rec, refs


def _validation_message(exc: ValidationError) -> list[dict]:
    out = []
    for err in exc.errors()[:20]:
        out.append({"loc": [str(p) for p in err.get("loc", [])][:8], "msg": str(err.get("msg", ""))[:200]})
    return out


def _ext(filename: str) -> str:
    ext = filename[filename.rfind(".") :].lower()
    return ".jpg" if ext == ".jpeg" else ext


def _summary_interaction(i) -> str:
    target = (i.accessibility.display() if i.accessibility else None) or ""
    return f"{i.kind} {i.key or target}".strip()[:200]


async def ingest_session(
    request: Request, device: Device, settings: Settings, state: SharedState, store: ArtifactStore
) -> IngestResult:
    length = request.headers.get("content-length")
    if length is not None:
        try:
            if int(length) > settings.max_upload_bytes:
                raise ApiError(413, "upload_too_large", "upload exceeds the configured limit")
        except ValueError:
            raise ApiError(400, "bad_content_length", "invalid Content-Length") from None
    ctype = request.headers.get("content-type", "")
    if not ctype.startswith("multipart/form-data"):
        raise ApiError(415, "multipart_required", "use multipart/form-data with manifest and files")
    try:
        form = await request.form(
            max_files=settings.max_frames + 1, max_fields=4, max_part_size=settings.max_manifest_bytes
        )
    except ApiError:
        raise
    except Exception:
        raise ApiError(400, "bad_multipart", "multipart body could not be parsed within limits") from None

    staging = None
    locked = False
    lock = None
    try:
        unknown = {k for k in form.keys() if k not in {"manifest", "files"}}
        if unknown:
            raise ApiError(400, "unexpected_fields", f"unexpected multipart fields: {sorted(unknown)[:5]}")
        manifests = form.getlist("manifest")
        if len(manifests) != 1 or not isinstance(manifests[0], str):
            raise ApiError(400, "manifest_required", "exactly one manifest JSON string field is required")
        raw_manifest = manifests[0]
        if len(raw_manifest.encode()) > settings.max_manifest_bytes:
            raise ApiError(413, "manifest_too_large", "manifest exceeds the configured limit")
        try:
            manifest = Manifest.model_validate_json(raw_manifest)
        except ValidationError as exc:
            raise ApiError(422, "invalid_manifest", "manifest failed validation", _validation_message(exc)) from None

        if manifest.project_id != device.project_id:
            raise ApiError(403, "project_mismatch", "device is not paired with this project")
        if len(manifest.frames) > settings.max_frames:
            raise ApiError(413, "too_many_frames", f"at most {settings.max_frames} frames")
        if len(manifest.interactions) > settings.max_interactions:
            raise ApiError(413, "too_many_interactions", f"at most {settings.max_interactions} interactions")
        if len(manifest.network) > settings.max_network:
            raise ApiError(413, "too_many_network_entries", f"at most {settings.max_network} network entries")
        session_id = str(manifest.id)
        manifest_digest = hashlib.sha256(raw_manifest.encode()).hexdigest()
        lock = _lock_for(session_id)
        await lock.acquire()
        locked = True
        existing = state.get_session(session_id)
        if existing and existing.project_id != manifest.project_id:
            raise ApiError(409, "session_exists", "a session with this id belongs to another project")
        if store.exists(manifest.project_id, session_id):
            marker = store.read_upload_marker(manifest.project_id, session_id)
            if not marker or marker.get("manifest_sha256") != manifest_digest:
                raise ApiError(409, "session_exists", "a different session with this id was already uploaded")
            # Safe retry of an identical upload: no new files are written.
            if existing is None:
                stored = store.load_manifest(manifest.project_id, session_id)
                rec, refs = session_records(stored, marker.get("device_id", device.device_id), store)
                state.upsert_session(rec)
                state.add_evidence_refs(session_id, refs)
                existing = rec
            return IngestResult(existing, 0, duplicate=True)

        uploads = form.getlist("files")
        frames_by_name = {f.filename: f for f in manifest.frames}
        seen: set[str] = set()
        for up in uploads:
            if not isinstance(up, UploadFile):
                raise ApiError(400, "bad_file_field", "files must be file attachments")
            name = up.filename or ""
            if "/" in name or "\\" in name or not SAFE_FILENAME.match(name) or ".." in name:
                raise ApiError(400, "unsafe_filename", "attachment filenames must be safe basenames")
            if name not in frames_by_name:
                raise ApiError(400, "unreferenced_file", f"attachment {name!r} is not referenced by the manifest")
            if name in seen:
                raise ApiError(400, "duplicate_file", f"attachment {name!r} sent twice")
            seen.add(name)
        missing = set(frames_by_name) - seen
        if missing:
            raise ApiError(400, "missing_files", f"{len(missing)} frame file(s) referenced but not attached")

        staging = store.staging_dir(manifest.project_id, session_id)
        total = len(raw_manifest)
        for up in uploads:
            frame = frames_by_name[up.filename]
            ext = _ext(frame.filename)
            dest = staging / store.frame_relpath(str(frame.id), ext)
            digest = hashlib.sha256()
            size = 0
            head = b""
            with open(dest, "xb") as out:
                dest.chmod(0o600)
                while True:
                    chunk = await up.read(CHUNK)
                    if not chunk:
                        break
                    if len(head) < 8:
                        head = (head + chunk)[:8]
                    size += len(chunk)
                    total += len(chunk)
                    if size > settings.max_file_bytes:
                        raise ApiError(413, "file_too_large", f"{frame.filename} exceeds {settings.max_file_bytes} bytes")
                    if total > settings.max_upload_bytes:
                        raise ApiError(413, "upload_too_large", "upload exceeds the configured limit")
                    digest.update(chunk)
                    out.write(chunk)
            if size == 0:
                raise ApiError(400, "empty_file", f"{frame.filename} is empty")
            if digest.hexdigest() != frame.sha256:
                raise ApiError(400, "sha256_mismatch", f"{frame.filename} does not match its sha256")
            if (ext == ".png" and not head.startswith(PNG_MAGIC)) or (ext == ".jpg" and not head.startswith(JPEG_MAGIC)):
                raise ApiError(400, "bad_image", f"{frame.filename} content does not match its extension")

        # Defense in depth: re-redact network evidence server side.
        redactions = 0
        clean_network = []
        for n in manifest.network:
            before = n.model_dump(mode="json")
            after = redact_network_entry(before)
            if after != before:
                redactions += 1
            clean_network.append(after)
        clean = manifest.model_dump(mode="json")
        clean["network"] = clean_network
        store.write_manifest(staging, clean)
        store.write_upload_marker(staging, {"manifest_sha256": manifest_digest, "device_id": device.device_id})
        final_dir = store.commit(manifest.project_id, session_id, staging)
        staging = None

        rec, refs = session_records(Manifest.model_validate(clean), device.device_id, store)
        try:
            state.upsert_session(rec)
            state.add_evidence_refs(session_id, refs)
        except Exception:
            shutil.rmtree(final_dir, ignore_errors=True)
            raise
        return IngestResult(rec, redactions, duplicate=False)
    finally:
        if staging is not None:
            store.discard(staging)
        if locked and lock is not None:
            lock.release()
        await form.close()
