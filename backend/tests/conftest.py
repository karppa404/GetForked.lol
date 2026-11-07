from __future__ import annotations

import hashlib
import json
import uuid
import warnings
from pathlib import Path

import pytest

warnings.filterwarnings("ignore", category=DeprecationWarning)

from fastapi.testclient import TestClient  # noqa: E402

from retrace.app import create_app  # noqa: E402
from retrace.config import LLMSettings, Settings  # noqa: E402

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def png_bytes(seed: int) -> bytes:
    return PNG + seed.to_bytes(4, "big")


def make_settings(tmp_path: Path, **overrides) -> Settings:
    llm = overrides.pop("llm", None) or LLMSettings(provider="offline_heuristic", model_default="offline")
    s = Settings(environment="test", data_dir=tmp_path / "data", dev_auth_enabled=True, inline_jobs=True, llm=llm, poll_min_interval_s=0.0)
    for k, v in overrides.items():
        setattr(s, k, v)
    return s


class Api:
    def __init__(self, client: TestClient):
        self.c = client

    def login(self, email="alice@example.com") -> dict:
        r = self.c.post("/v1/auth/dev", json={"email": email, "name": email.split("@")[0]})
        assert r.status_code == 200, r.text
        return {"Authorization": f"Bearer {r.json()['access_token']}"}

    def project(self, headers, name="Demo") -> str:
        r = self.c.post("/v1/projects", json={"name": name}, headers=headers)
        assert r.status_code == 201, r.text
        return r.json()["id"]

    def pair(self, headers, project_id, device_name="Alice's Mac") -> dict:
        p = self.c.post("/v1/pairings", json={"project_id": project_id}, headers=headers).json()
        claim = self.c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": device_name}).json()
        r = self.c.post(f"/v1/pairings/{p['pairing_id']}/approve", json={"claim_id": claim["claim_id"]}, headers=headers)
        assert r.status_code == 200, r.text
        r = self.c.post(f"/v1/pairings/claims/{claim['claim_id']}/poll", json={"claim_secret": claim["claim_secret"]})
        assert r.status_code == 200 and r.json()["status"] == "approved", r.text
        return {"Authorization": f"Bearer {r.json()['device_token']}"}

    def upload(self, device_headers, manifest: dict, files: dict[str, bytes]):
        parts = [("files", (name, data, "image/png")) for name, data in files.items()]
        return self.c.post(
            "/v1/sessions", data={"manifest": json.dumps(manifest)}, files=parts, headers=device_headers
        )


def build_manifest(project_id: str, *, network=True, status: str | None = None, n_frames=3) -> tuple[dict, dict[str, bytes]]:
    frames, files = [], {}
    for k in range(n_frames):
        data = png_bytes(k)
        name = f"frame-{k}.png"
        files[name] = data
        frames.append(
            {"id": str(uuid.uuid4()), "timestamp_ms": k * 1000, "filename": name, "width": 1280, "height": 800, "sha256": hashlib.sha256(data).hexdigest()}
        )
    interactions = [
        {
            "id": str(uuid.uuid4()),
            "timestamp_ms": k * 1000 + 500,
            "kind": "click",
            "x": 10.0,
            "y": 20.0,
            "accessibility": {"role": "AXButton", "title": f"Button {k}", "window_title": f"Window {k}"},
            "before_frame_id": frames[k]["id"],
            "after_frame_id": frames[k + 1]["id"],
        }
        for k in range(n_frames - 1)
    ]
    net = []
    if network:
        net = [
            {
                "id": str(uuid.uuid4()),
                "timestamp_ms": 900,
                "method": "POST",
                "url": "https://api.example.com/v1/orders?api_key=abc123SECRETvalue456789xyz&page=2",
                "status": 201,
                "request_headers": {"Authorization": "Bearer sk-livesecretvalue0123456789", "Content-Type": "application/json"},
                "request_body": '{"password":"hunter2","item":"widget"}',
            }
        ]
    manifest = {
        "schema_version": 1,
        "id": str(uuid.uuid4()),
        "project_id": project_id,
        "app": {"name": "Ledger", "bundle_id": "com.example.ledger", "pid": 4242},
        "started_at": "2026-11-07T20:00:00Z",
        "duration_ms": n_frames * 1000,
        "interactions": interactions,
        "frames": frames,
        "network": net,
        "network_status": status or ("observed" if network else "not_captured"),
        "redaction": {"reviewed": True},
    }
    return manifest, files


@pytest.fixture
def settings(tmp_path):
    return make_settings(tmp_path)


@pytest.fixture
def app(settings):
    return create_app(settings)


@pytest.fixture
def client(app):
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 50000)) as c:
        yield c


@pytest.fixture
def api(client):
    return Api(client)
