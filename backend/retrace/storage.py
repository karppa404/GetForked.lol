"""Private artifact storage on local disk.

Layout: <data_dir>/artifacts/<project_id>/<session_id>/{manifest.json,frames/<frame_id>.<ext>}
Stored filenames are derived from validated UUIDs, never from client input.
Directories are 0700 and files 0600. Nothing here is served statically.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path

from .models import Manifest

_SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class ArtifactStore:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)

    def _dir(self, project_id: str, session_id: str) -> Path:
        if not _SAFE_ID.match(project_id) or not _SAFE_ID.match(session_id):
            raise ValueError("unsafe storage id")
        path = (self.root / project_id / session_id).resolve()
        if self.root not in path.parents:
            raise ValueError("storage path escapes root")
        return path

    def staging_dir(self, project_id: str, session_id: str) -> Path:
        final = self._dir(project_id, session_id)
        staging = final.parent / f".staging-{session_id}"
        if staging.exists():
            shutil.rmtree(staging)
        (staging / "frames").mkdir(parents=True)
        for p in (final.parent, staging, staging / "frames"):
            os.chmod(p, 0o700)
        return staging

    def commit(self, project_id: str, session_id: str, staging: Path) -> Path:
        final = self._dir(project_id, session_id)
        if final.exists():
            raise FileExistsError("session already stored")
        staging.rename(final)
        return final

    def discard(self, staging: Path) -> None:
        if staging.exists() and self.root in staging.resolve().parents:
            shutil.rmtree(staging, ignore_errors=True)

    @staticmethod
    def frame_relpath(frame_id: str, ext: str) -> str:
        return f"frames/{frame_id}{ext}"

    def frame_path(self, project_id: str, session_id: str, rel: str) -> Path:
        base = self._dir(project_id, session_id)
        path = (base / rel).resolve()
        if base not in path.parents:
            raise ValueError("artifact path escapes session")
        return path

    def write_manifest(self, staging: Path, manifest_json: dict) -> None:
        path = staging / "manifest.json"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(manifest_json, f)

    def write_upload_marker(self, staging: Path, marker: dict) -> None:
        fd = os.open(staging / "upload.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(marker, f)

    def read_upload_marker(self, project_id: str, session_id: str) -> dict | None:
        path = self._dir(project_id, session_id) / "upload.json"
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            return None

    def load_manifest(self, project_id: str, session_id: str) -> Manifest:
        path = self._dir(project_id, session_id) / "manifest.json"
        return Manifest.model_validate_json(path.read_text())

    def exists(self, project_id: str, session_id: str) -> bool:
        return self._dir(project_id, session_id).exists()
