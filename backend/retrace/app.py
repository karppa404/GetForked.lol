"""Retrace HTTP API v1 (see backend/README.md for the response contract)."""

from __future__ import annotations

import hashlib
import json
import logging
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse, Response

from . import __version__
from .analysis.llm import ChatProvider, GlobalLimiter, OpenAICompatibleProvider, budget_summary
from .analysis.offline import OfflineHeuristicProvider
from .analysis.pipeline import Pipeline, PipelineDeps
from .authstore import AuthStore, Device, User
from .config import Settings, is_loopback_host
from .errors import ApiError
from .google_auth import GoogleAuthError, GoogleVerifier
from .graph import ELEMENT_ID_RE, apply_corrections
from .ingest import ingest_session
from .models import (
    ClaimPoll,
    CorrectionPut,
    DevLoginRequest,
    GoogleLoginRequest,
    PairingApprove,
    PairingClaim,
    BoardPut,
    PairingCreate,
    ProjectCreate,
    RealtimeViewer,
)
from .ratelimit import RateLimiter
from .security import format_pairing_code, iso, normalize_pairing_code, parse_iso, utcnow
from .state import SharedState, StateUnavailable, build_state
from .state.base import CorrectionRec, JobRec, ProjectRec, SessionRec
from .storage import ArtifactStore

log = logging.getLogger("retrace")

_FORWARDING_HEADERS = ("x-forwarded-for", "forwarded", "x-real-ip", "x-forwarded-host", "cf-connecting-ip")


class _NullLedger:
    def record_usage(self, *args, **kwargs) -> None:
        pass

    def usage_totals(self) -> dict:
        return {"calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "includes_estimates": False}


@dataclass
class Services:
    settings: Settings
    auth: AuthStore
    state: SharedState
    store: ArtifactStore
    provider: ChatProvider | None
    google: GoogleVerifier | None
    limiter: GlobalLimiter
    executor: ThreadPoolExecutor
    sleep: Callable[[float], None] | None = None
    claim_limiter: RateLimiter = field(default_factory=lambda: RateLimiter(10, 60))
    login_limiter: RateLimiter = field(default_factory=lambda: RateLimiter(20, 60))
    analyze_lock: threading.Lock = field(default_factory=threading.Lock)


class BodySizeLimit:
    """Reject request bodies larger than the upload limit, even without Content-Length."""

    def __init__(self, app, max_bytes: int):
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    raise ApiError(413, "upload_too_large", "request body exceeds the configured limit")
            return message

        await self.app(scope, limited_receive, send)


def _bearer(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    if header[:7].lower() == "bearer ":
        token = header[7:].strip()
        return token or None
    return None


def create_app(
    settings: Settings | None = None,
    *,
    state: SharedState | None = None,
    provider: ChatProvider | None = None,
    google_verifier: GoogleVerifier | None = None,
    sleep: Callable[[float], None] | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.validate()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    settings.data_dir.chmod(0o700)
    if provider is None:
        if settings.llm.provider == "offline_heuristic":
            provider = OfflineHeuristicProvider()
        elif settings.llm.configured:
            provider = OpenAICompatibleProvider(settings.llm.base_url, settings.llm.api_key, settings.llm.timeout_s)
    if google_verifier is None and settings.google_client_id:
        google_verifier = GoogleVerifier(settings.google_client_id, settings.google_allowed_domains)
    services = Services(
        settings=settings,
        auth=AuthStore(settings.data_dir / "auth.sqlite3"),
        state=state or build_state(settings),
        store=ArtifactStore(settings.data_dir / "artifacts"),
        provider=provider,
        google=google_verifier,
        limiter=GlobalLimiter(settings.llm.max_concurrent_calls),
        executor=ThreadPoolExecutor(max_workers=max(1, settings.llm.max_concurrent_jobs), thread_name_prefix="retrace-job"),
        sleep=sleep,
    )

    app = FastAPI(title="Retrace API", version=__version__, docs_url=None if settings.is_production else "/docs", redoc_url=None)
    app.state.services = services
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type"],
        max_age=600,
    )
    app.add_middleware(BodySizeLimit, max_bytes=settings.max_upload_bytes + 1024 * 1024)

    @app.exception_handler(ApiError)
    async def _api_error(_request: Request, exc: ApiError):
        return JSONResponse(exc.body(), status_code=exc.status, headers=exc.headers)

    @app.exception_handler(StateUnavailable)
    async def _state_down(_request: Request, exc: StateUnavailable):
        log.warning("shared state unavailable: %s", exc)
        return JSONResponse({"error": "state_unavailable", "message": "shared state backend is unavailable"}, status_code=503)

    @app.exception_handler(RequestValidationError)
    async def _validation(_request: Request, exc: RequestValidationError):
        details = [{"loc": [str(p) for p in e.get("loc", [])][:8], "msg": str(e.get("msg", ""))[:200]} for e in exc.errors()[:20]]
        return JSONResponse({"error": "invalid_request", "message": "request failed validation", "details": details}, status_code=422)

    # ---------------- dependencies ----------------
    def svc() -> Services:
        return services

    def current_user(request: Request) -> User:
        token = _bearer(request)
        user = services.auth.user_for_access_token(token) if token and token.startswith("rta_") else None
        if not user:
            raise ApiError(401, "unauthorized", "browser access token required", headers={"WWW-Authenticate": "Bearer"})
        return user

    def current_device(request: Request) -> Device:
        token = _bearer(request)
        device = services.auth.device_for_token(token) if token and token.startswith("rtd_") else None
        if not device:
            raise ApiError(401, "unauthorized", "device token required", headers={"WWW-Authenticate": "Bearer"})
        return device

    def current_principal(request: Request) -> User | Device:
        token = _bearer(request) or ""
        if token.startswith("rtd_"):
            return current_device(request)
        return current_user(request)

    def owned_project(project_id: str, user: User) -> ProjectRec:
        project = services.state.get_project(project_id)
        if not project or project.owner_user_id != user.user_id:
            raise ApiError(404, "not_found", "project not found")
        return project

    def accessible_session(session_id: str, principal: User | Device) -> SessionRec:
        try:
            uuid.UUID(session_id)
        except ValueError:
            raise ApiError(404, "not_found", "session not found") from None
        session = services.state.get_session(session_id)
        if not session:
            raise ApiError(404, "not_found", "session not found")
        if isinstance(principal, Device):
            if principal.project_id != session.project_id:
                raise ApiError(404, "not_found", "session not found")
        else:
            project = services.state.get_project(session.project_id)
            if not project or project.owner_user_id != principal.user_id:
                raise ApiError(404, "not_found", "session not found")
        return session

    def client_ip(request: Request) -> str:
        return request.client.host if request.client else "unknown"

    # ---------------- health ----------------
    @app.get("/health")
    def health():
        state_status = services.state.status()
        llm = settings.llm
        ledger = services.auth if services.provider and services.provider.name != "offline_heuristic" else _NullLedger()
        body = {
            "status": "ok" if state_status.get("ready") else "degraded",
            "version": __version__,
            "environment": settings.environment,
            "state": {k: v for k, v in state_status.items() if k in {"backend", "label", "ready", "realtime", "error", "note"}},
            "auth": {
                "google_configured": services.google is not None,
                "dev_login_enabled": settings.dev_auth_enabled,
            },
            "analysis": {
                "provider": services.provider.name if services.provider else None,
                "configured": services.provider is not None,
                "base_url_configured": bool(llm.base_url),
                "api_key_configured": bool(llm.api_key),
                "models": {s: llm.model_for(s) for s in ("workflow", "network", "reconcile", "publish")},
                "vision_enabled": llm.vision_enabled,
                "budget": budget_summary(llm, ledger),
            },
        }
        return JSONResponse(body, status_code=200)

    # ---------------- auth ----------------
    def _login_response(user: User) -> dict:
        token, expires = services.auth.issue_access_token(user.user_id, settings.access_token_ttl_s)
        return {"access_token": token, "token_type": "bearer", "expires_at": expires, "user": user.public()}

    @app.post("/v1/auth/google")
    def auth_google(body: GoogleLoginRequest, request: Request):
        if services.google is None:
            raise ApiError(503, "google_login_not_configured", "Google login is not configured on this server")
        if not services.login_limiter.allow(f"google:{client_ip(request)}"):
            raise ApiError(429, "rate_limited", "too many login attempts")
        try:
            ident = services.google.verify(body.credential)
        except GoogleAuthError as exc:
            raise ApiError(401, "invalid_credential", str(exc)) from None
        user = services.auth.upsert_user("google", ident.subject, ident.email, ident.name)
        return _login_response(user)

    @app.post("/v1/auth/dev")
    def auth_dev(body: DevLoginRequest, request: Request):
        if not settings.dev_auth_enabled or settings.is_production:
            raise ApiError(404, "not_found", "not found")
        host_header = request.headers.get("host", "")
        hostname = urlsplit(f"//{host_header}").hostname
        forwarded = any(h in request.headers for h in _FORWARDING_HEADERS)
        if not is_loopback_host(client_ip(request)) or not is_loopback_host(hostname) or forwarded:
            raise ApiError(403, "dev_login_loopback_only", "development login is only available from loopback")
        email = body.email.strip().lower()
        user = services.auth.upsert_user("dev", email, email, body.name)
        return _login_response(user)

    @app.get("/v1/auth/me")
    def auth_me(user: User = Depends(current_user)):
        return {"user": user.public()}

    @app.post("/v1/auth/logout", status_code=204)
    def auth_logout(request: Request, _user: User = Depends(current_user)):
        services.auth.revoke_access_token(_bearer(request))
        return Response(status_code=204)

    # ---------------- projects ----------------
    def _project_out(p: ProjectRec) -> dict:
        return {"id": p.project_id, "name": p.name, "created_at": p.created_at}

    @app.get("/v1/projects")
    def list_projects(user: User = Depends(current_user)):
        return {"projects": [_project_out(p) for p in services.state.list_projects(user.user_id)]}

    @app.post("/v1/projects", status_code=201)
    def create_project(body: ProjectCreate, user: User = Depends(current_user)):
        p = ProjectRec(str(uuid.uuid4()), body.name, user.user_id, iso(utcnow()))
        services.state.upsert_project(p)
        return _project_out(p)

    @app.get("/v1/projects/{project_id}/sessions")
    def list_sessions(project_id: str, user: User = Depends(current_user)):
        owned_project(project_id, user)
        return {"sessions": [_session_out(s) for s in services.state.list_sessions(project_id)]}

    @app.get("/v1/projects/{project_id}/devices")
    def list_devices(project_id: str, user: User = Depends(current_user)):
        owned_project(project_id, user)
        return {"devices": [d.public() for d in services.auth.list_devices(project_id)]}

    @app.delete("/v1/devices/{device_id}", status_code=204)
    def revoke_device(device_id: str, user: User = Depends(current_user)):
        device = services.auth.get_device(device_id)
        if not device:
            raise ApiError(404, "not_found", "device not found")
        owned_project(device.project_id, user)
        services.auth.revoke_device(device_id)
        return Response(status_code=204)

    @app.get("/v1/devices/me")
    def device_me(device: Device = Depends(current_device)):
        return device.public()

    @app.delete("/v1/devices/me", status_code=204)
    def device_unpair(device: Device = Depends(current_device)):
        services.auth.revoke_device(device.device_id)
        return Response(status_code=204)

    # ---------------- pairing ----------------
    @app.post("/v1/pairings", status_code=201)
    def create_pairing(body: PairingCreate, user: User = Depends(current_user)):
        owned_project(body.project_id, user)
        p = services.auth.create_pairing(body.project_id, user.user_id, settings.pairing_ttl_s)
        return {"pairing_id": p["pairing_id"], "code": format_pairing_code(p["code"]), "expires_at": p["expires_at"]}

    def _owned_pairing(pairing_id: str, user: User) -> dict:
        p = services.auth.get_pairing(pairing_id)
        if not p or p["created_by"] != user.user_id:
            raise ApiError(404, "not_found", "pairing not found")
        owned_project(p["project_id"], user)
        return p

    @app.get("/v1/pairings/{pairing_id}")
    def get_pairing(pairing_id: str, user: User = Depends(current_user)):
        p = _owned_pairing(pairing_id, user)
        return {k: p[k] for k in ("pairing_id", "project_id", "status", "expires_at", "claims")}

    @app.post("/v1/pairings/claim", status_code=201)
    def claim_pairing(body: PairingClaim, request: Request):
        if not services.claim_limiter.allow(f"claim:{client_ip(request)}"):
            raise ApiError(429, "rate_limited", "too many pairing attempts", headers={"Retry-After": "60"})
        code = normalize_pairing_code(body.code)
        result = services.auth.claim(code, body.device_name, settings.claim_ttl_s) if len(code) == 8 else None
        if not result:
            raise ApiError(400, "invalid_or_expired_code", "pairing code is invalid, expired or already used")
        return result

    def _decide(pairing_id: str, body: PairingApprove, user: User, approve: bool):
        _owned_pairing(pairing_id, user)
        outcome = services.auth.decide_claim(pairing_id, str(body.claim_id), approve, user.user_id)
        if outcome == "not_found":
            raise ApiError(404, "not_found", "claim not found for this pairing")
        if outcome == "not_pending":
            raise ApiError(409, "claim_not_pending", "claim was already decided")
        if outcome == "expired":
            raise ApiError(410, "claim_expired", "claim expired; start a new pairing")
        return {"claim_id": str(body.claim_id), "status": outcome}

    @app.post("/v1/pairings/{pairing_id}/approve")
    def approve_claim(pairing_id: str, body: PairingApprove, user: User = Depends(current_user)):
        return _decide(pairing_id, body, user, True)

    @app.post("/v1/pairings/{pairing_id}/reject")
    def reject_claim(pairing_id: str, body: PairingApprove, user: User = Depends(current_user)):
        return _decide(pairing_id, body, user, False)

    @app.post("/v1/pairings/claims/{claim_id}/poll")
    def poll_claim(claim_id: str, body: ClaimPoll):
        r = services.auth.poll(claim_id, body.claim_secret, settings.poll_min_interval_s, settings.poll_max_count)
        if r.status == "not_found":
            raise ApiError(404, "not_found", "claim not found")
        if r.status == "rate_limited":
            raise ApiError(429, "poll_too_fast", "poll less frequently", headers={"Retry-After": str(max(1, round(r.retry_after_s or 1)))})
        if r.status == "approved":
            return {"status": "approved", "device_token": r.device_token, "project_id": r.project_id}
        if r.status == "pending":
            return {"status": "pending", "poll_after_ms": int(settings.poll_min_interval_s * 2000)}
        # rejected | expired | consumed: terminal; recorder must start a new pairing
        return JSONResponse({"status": r.status}, status_code=410 if r.status != "rejected" else 403)

    # ---------------- sessions ----------------
    def _correction_out(c: CorrectionRec) -> dict:
        return {"element_id": c.element_id, "label": c.label, "updated_at": c.updated_at, "author": c.author_user_id}

    def _session_out(s: SessionRec) -> dict:
        return {
            "id": s.session_id,
            "project_id": s.project_id,
            "status": s.status,
            "app": {"name": s.app_name, "bundle_id": s.bundle_id},
            "task": s.task,
            "started_at": s.started_at,
            "duration_ms": s.duration_ms,
            "counts": {"frames": s.frame_count, "interactions": s.interaction_count, "network": s.network_count},
            "network_status": s.network_status,
            "uploaded_at": s.uploaded_at,
            "uploaded_by_device": s.uploaded_by_device,
        }

    def _job_out(j: JobRec, with_stages: bool = False) -> dict:
        out = {
            "id": j.job_id,
            "status": j.status,
            "stage": j.stage,
            "error": j.error,
            "usage": {
                "calls": j.calls_used,
                "prompt_tokens": j.prompt_tokens,
                "completion_tokens": j.completion_tokens,
                "estimated": j.usage_estimated,
            },
            "created_at": j.created_at,
            "updated_at": j.updated_at,
        }
        if with_stages:
            out["stages"] = _stages_out(j)
        return out

    STAGE_LABELS = {"workflow": "Workflow analyst", "network": "Network analyst", "reconcile": "Reconciliation", "publish": "Publisher"}

    def _stages_out(j: JobRec) -> list[dict]:
        """All four stages in order; status in pending|running|done|failed|skipped."""
        recorded = {st.stage: st for st in services.state.list_stages(j.job_id)}
        out = []
        for name in ("workflow", "network", "reconcile", "publish"):
            rec = recorded.get(name)
            detail = None
            if rec is None:
                running = j.status == "running" and (j.stage == name or (name == "network" and j.stage == "workflow"))
                status = "running" if running else ("failed" if j.status == "failed" else "pending")
                if status == "failed":
                    status, detail = "skipped", "not reached"
            else:
                try:
                    summary = json.loads(rec.summary_json)
                except ValueError:
                    summary = {}
                status = {"succeeded": "done", "fallback": "done"}.get(rec.status, rec.status)
                if rec.status == "fallback":
                    detail = "model output rejected; validated fallback used"
                detail = detail or summary.get("reason") or summary.get("error")
            out.append({"name": name, "label": STAGE_LABELS[name], "status": status, "detail": detail, "updated_at": rec.updated_at if rec else None})
        return out

    @app.post("/v1/sessions", status_code=201)
    async def upload_session(request: Request, device: Device = Depends(current_device)):
        result = await ingest_session(request, device, settings, services.state, services.store)
        body = {"id": result.session.session_id, "status": "uploaded", "server_redactions": result.server_redactions}
        if result.duplicate:
            return JSONResponse(body | {"duplicate": True}, status_code=200)
        return body

    @app.get("/v1/sessions/{session_id}")
    def get_session(session_id: str, principal=Depends(current_principal)):
        s = accessible_session(session_id, principal)
        jobs = services.state.list_jobs(session_id)
        graphs = services.state.list_graphs(session_id)
        latest = graphs[-1] if graphs else None
        body = _session_out(s) | {
            "job": _job_out(jobs[-1], with_stages=True) if jobs else None,
            "jobs": [_job_out(j) for j in jobs],
            "graph_meta": None
            if not latest
            else {
                "graph_id": latest.graph_id,
                "version": latest.version,
                "job_id": latest.job_id,
                "published_at": latest.published_at,
                "network_status": latest.network_status,
                "node_count": latest.node_count,
                "edge_count": latest.edge_count,
                "url": f"/v1/sessions/{session_id}/graph",
            },
        }
        if isinstance(principal, Device):
            return body  # recorders get status only, not evidence or graph content
        corrections = services.state.list_corrections(session_id)
        body |= _evidence_out(s) | {
            # agent graph without corrections applied; corrections are listed separately
            "graph": json.loads(latest.graph_json) if latest else None,
            "corrections": [_correction_out(c) for c in corrections],
            "board_url": services.state.get_board_url(session_id),
        }
        return body

    def _evidence_out(s: SessionRec) -> dict:
        m = services.store.load_manifest(s.project_id, s.session_id)
        data = m.model_dump(mode="json", exclude_none=True)
        for f in data["frames"]:
            f["image_url"] = f"/v1/sessions/{s.session_id}/frames/{f['id']}"
        return {k: data[k] for k in ("frames", "interactions", "network", "redaction")}

    @app.get("/v1/sessions/{session_id}/evidence")
    def get_evidence(session_id: str, user: User = Depends(current_user)):
        s = accessible_session(session_id, user)
        return {"id": s.session_id, "network_status": s.network_status} | _evidence_out(s)

    @app.put("/v1/sessions/{session_id}/board")
    def put_board(session_id: str, body: BoardPut, user: User = Depends(current_user)):
        accessible_session(session_id, user)
        services.state.set_board_url(session_id, body.board_url, user.user_id, iso(utcnow()))
        return {"session_id": session_id, "board_url": body.board_url}

    @app.get("/v1/sessions/{session_id}/frames/{frame_id}")
    def get_frame(session_id: str, frame_id: str, user: User = Depends(current_user)):
        s = accessible_session(session_id, user)
        ref = next((r for r in services.state.list_evidence_refs(session_id) if r.evidence_id == frame_id and r.kind == "frame"), None)
        if not ref or not ref.artifact_key:
            raise ApiError(404, "not_found", "frame not found")
        path = services.store.frame_path(s.project_id, s.session_id, ref.artifact_key)
        media = "image/png" if path.suffix == ".png" else "image/jpeg"
        return FileResponse(path, media_type=media, headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"})

    def _run_job(job: JobRec, session: SessionRec) -> None:
        state = services.state
        ledger = services.auth if services.provider.name != "offline_heuristic" else _NullLedger()

        def load_frame(frame_id: str) -> bytes | None:
            ref = next((r for r in state.list_evidence_refs(session.session_id) if r.evidence_id == frame_id), None)
            if not ref or not ref.artifact_key:
                return None
            return services.store.frame_path(session.project_id, session.session_id, ref.artifact_key).read_bytes()

        deps = PipelineDeps(
            state=state,
            provider=services.provider,
            llm_settings=settings.llm,
            ledger=ledger,
            limiter=services.limiter,
            load_manifest=lambda: services.store.load_manifest(session.project_id, session.session_id),
            load_frame=load_frame,
            sleep=services.sleep,
        )
        def set_status(status: str) -> None:
            current = state.get_session(session.session_id) or session
            current.status = status
            state.upsert_session(current)

        try:
            set_status("analyzing")
            graph = Pipeline(deps, job, session.session_id).run()
            set_status("analyzed" if graph else "failed")
        except Exception:
            log.exception("analysis job %s crashed", job.job_id)
            try:
                set_status("failed")
            except Exception:
                pass

    @app.post("/v1/sessions/{session_id}/analyze", status_code=202)
    async def analyze(session_id: str, request: Request, principal=Depends(current_principal)):
        body = await _analyze_body(request)
        return await run_in_threadpool(_start_analysis, session_id, principal, bool(body.get("rerun")))

    async def _analyze_body(request: Request) -> dict:
        raw = await request.body()
        if not raw.strip():
            return {}
        try:
            data = json.loads(raw)
        except ValueError:
            raise ApiError(400, "invalid_json", "body must be JSON") from None
        if not isinstance(data, dict) or set(data) - {"rerun"} or not isinstance(data.get("rerun", False), bool):
            raise ApiError(422, "invalid_request", 'body must be {} or {"rerun": true|false}')
        return data

    def _start_analysis(session_id: str, principal, rerun: bool):
        s = accessible_session(session_id, principal)
        if services.provider is None:
            raise ApiError(503, "analysis_not_configured", "model endpoint and model IDs are not configured")
        with services.analyze_lock:
            jobs = services.state.list_jobs(session_id)
            latest = jobs[-1] if jobs else None
            if latest:
                age = (utcnow() - parse_iso(latest.created_at)).total_seconds()
                in_flight = latest.status in {"queued", "running"}
                # Client retries (lost responses) must never start duplicate jobs. In-flight jobs
                # are always reused; a new job needs {"rerun": true}, or a failed job older than
                # the retry window.
                recent = age < settings.analyze_dedupe_window_s
                if in_flight or (not rerun and (recent or latest.status == "succeeded")):
                    return JSONResponse({"job_id": latest.job_id, "status": latest.status, "existing": True}, status_code=200)
            now = iso(utcnow())
            job = JobRec(str(uuid.uuid4()), session_id, "queued", "queued", None, 0, 0, 0, False, now, now)
            services.state.upsert_job(job)
            current = services.state.get_session(session_id) or s
            current.status = "queued"
            services.state.upsert_session(current)
        if settings.inline_jobs:
            _run_job(job, s)
            return JSONResponse({"job_id": job.job_id, "status": job.status}, status_code=202)
        services.executor.submit(_run_job, job, s)
        return JSONResponse({"job_id": job.job_id, "status": job.status}, status_code=202)

    def _latest_graph(session_id: str, version: int | None) -> dict:
        graphs = services.state.list_graphs(session_id)
        if version is not None:
            graphs = [g for g in graphs if g.version == version]
        if not graphs:
            raise ApiError(404, "graph_not_found", "no published graph for this session yet")
        return json.loads(graphs[-1].graph_json)

    @app.get("/v1/sessions/{session_id}/graph")
    def get_graph(session_id: str, version: int | None = None, corrections: bool = True, download: bool = False, principal=Depends(current_principal)):
        accessible_session(session_id, principal)
        graph = _latest_graph(session_id, version)
        if corrections:
            graph = apply_corrections(graph, services.state.list_corrections(session_id))
        headers = {"Cache-Control": "private, no-store"}
        if download:
            headers["Content-Disposition"] = f'attachment; filename="retrace-{session_id}-v{graph["graph_version"]}.json"'
        return JSONResponse(graph, headers=headers)


    @app.get("/v1/sessions/{session_id}/corrections")
    def list_corrections(session_id: str, user: User = Depends(current_user)):
        accessible_session(session_id, user)
        items = [_correction_out(c) for c in services.state.list_corrections(session_id)]
        version = hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()[:16]
        return JSONResponse({"corrections": items, "version": version}, headers={"ETag": f'"{version}"', "Cache-Control": "private, no-store"})

    @app.put("/v1/sessions/{session_id}/corrections/{element_id}")
    def put_correction(session_id: str, element_id: str, body: CorrectionPut, user: User = Depends(current_user)):
        accessible_session(session_id, user)
        if not ELEMENT_ID_RE.match(element_id):
            raise ApiError(400, "invalid_element_id", "element id is not a graph node or edge id")
        known = set()
        for g in services.state.list_graphs(session_id):
            data = json.loads(g.graph_json)
            known |= {n["id"] for n in data["nodes"]} | {e["id"] for e in data["edges"]}
        if element_id not in known:
            raise ApiError(404, "unknown_element", "element does not exist in any published graph version")
        c = CorrectionRec(f"{session_id}:{element_id}", session_id, element_id, body.label, user.user_id, iso(utcnow()))
        services.state.set_correction(c)
        return _correction_out(c)

    @app.delete("/v1/sessions/{session_id}/corrections/{element_id}", status_code=204)
    def delete_correction(session_id: str, element_id: str, user: User = Depends(current_user)):
        accessible_session(session_id, user)
        services.state.delete_correction(f"{session_id}:{element_id}")
        return Response(status_code=204)

    # ---------------- realtime (SpacetimeDB) ----------------
    @app.get("/v1/realtime")
    def realtime_config(_user: User = Depends(current_user)):
        st = services.state.status()
        out: dict[str, Any] = {"backend": st.get("backend"), "ready": st.get("ready", False), "realtime": st.get("realtime")}
        if st.get("backend") == "spacetimedb":
            out |= {"uri": st.get("uri"), "database": st.get("database"), "views": st.get("views")}
        return out

    def _viewer(project_id: str, body: RealtimeViewer, user: User, grant: bool):
        owned_project(project_id, user)
        if services.state.backend != "spacetimedb":
            raise ApiError(409, "realtime_unavailable", "realtime subscriptions require the spacetimedb state backend")
        if grant:
            services.state.grant_viewer(project_id, body.identity, user.user_id)
        else:
            services.state.revoke_viewer(project_id, body.identity)
        return {"project_id": project_id, "identity": body.identity.lower().removeprefix("0x"), "granted": grant}

    @app.post("/v1/projects/{project_id}/realtime-viewers")
    def grant_viewer(project_id: str, body: RealtimeViewer, user: User = Depends(current_user)):
        return _viewer(project_id, body, user, True)

    @app.delete("/v1/projects/{project_id}/realtime-viewers")
    def revoke_viewer(project_id: str, body: RealtimeViewer, user: User = Depends(current_user)):
        return _viewer(project_id, body, user, False)

    return app
