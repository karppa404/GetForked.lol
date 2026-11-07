import copy
import hashlib
import json
import os
import stat
import uuid

import pytest
from fastapi.testclient import TestClient

from retrace.app import create_app

from .conftest import PNG, Api, build_manifest, make_settings


@pytest.fixture
def paired(api):
    alice = api.login()
    pid = api.project(alice)
    return api, alice, pid, api.pair(alice, pid)


def test_valid_upload_is_private_and_redacted(paired, settings):
    api, alice, pid, device = paired
    manifest, files = build_manifest(pid)
    r = api.upload(device, manifest, files)
    assert r.status_code == 201, r.text
    assert r.json()["id"] == manifest["id"] and r.json()["status"] == "uploaded"
    assert r.json()["server_redactions"] == 1

    session_dir = settings.data_dir / "artifacts" / pid / manifest["id"]
    stored = json.loads((session_dir / "manifest.json").read_text())
    text = json.dumps(stored)
    for secret in ("hunter2", "sk-livesecretvalue", "abc123SECRETvalue"):
        assert secret not in text
    assert "page=2" in stored["network"][0]["url"]
    # frames stored under server-chosen names with private permissions
    for f in manifest["frames"]:
        path = session_dir / "frames" / f"{f['id']}.png"
        assert path.exists()
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(session_dir.parent).st_mode) == 0o700

    listing = api.c.get(f"/v1/projects/{pid}/sessions", headers=alice).json()["sessions"]
    assert [s["id"] for s in listing] == [manifest["id"]]
    assert listing[0]["counts"] == {"frames": 3, "interactions": 2, "network": 1}

    frame = manifest["frames"][0]
    img = api.c.get(f"/v1/sessions/{manifest['id']}/frames/{frame['id']}", headers=alice)
    assert img.status_code == 200 and img.content == files[frame["filename"]]
    assert img.headers["cache-control"] == "private, no-store"


def test_duplicate_session_rejected(paired):
    api, _, pid, device = paired
    manifest, files = build_manifest(pid)
    assert api.upload(device, manifest, files).status_code == 201
    assert api.upload(device, manifest, files).status_code == 409


@pytest.mark.parametrize(
    "mutate, code",
    [
        (lambda m: m["frames"][0].update(filename="../../etc/passwd.png"), 422),
        (lambda m: m["frames"][0].update(filename="sub/dir.png"), 422),
        (lambda m: m["frames"][0].update(filename=".hidden.png"), 422),
        (lambda m: m["frames"][0].update(filename="frame.exe"), 422),
        (lambda m: m.update(redaction={"reviewed": False}), 422),
        (lambda m: m.update(schema_version=2), 422),
        (lambda m: m.update(unexpected="x"), 422),
        (lambda m: m.update(started_at="2026-11-07T14:00:00-06:00"), 422),
        (lambda m: m["interactions"][0].update(key="a"), 422),
        (lambda m: m["interactions"][0].update(after_frame_id=str(uuid.uuid4())), 422),
        (lambda m: m["interactions"][0].update(id=m["frames"][0]["id"]), 422),
        (lambda m: m["interactions"][0].update(timestamp_ms=10**9), 422),
        (lambda m: m["network"][0].update(url="file:///etc/passwd"), 422),
        (lambda m: m.update(network_capture={"status": "not_captured"}), 422),
    ],
)
def test_manifest_validation(paired, mutate, code):
    api, _, pid, device = paired
    manifest, files = build_manifest(pid)
    bad = copy.deepcopy(manifest)
    mutate(bad)
    r = api.upload(device, bad, files)
    assert r.status_code == code, r.text


def test_named_keys_allowed(paired):
    api, _, pid, device = paired
    manifest, files = build_manifest(pid)
    manifest["interactions"][0]["key"] = "cmd+s"
    manifest["interactions"][1]["key"] = "redacted"
    assert api.upload(device, manifest, files).status_code == 201


def test_untrusted_attachment_names(paired):
    api, _, pid, device = paired
    manifest, files = build_manifest(pid)
    data = list(files.items())
    # attachment with traversal name
    parts = [("files", ("../frame-0.png", data[0][1], "image/png"))] + [("files", (n, d, "image/png")) for n, d in data[1:]]
    r = api.c.post("/v1/sessions", data={"manifest": json.dumps(manifest)}, files=parts, headers=device)
    assert r.status_code == 400, r.text
    # unreferenced extra file
    extra = dict(files, **{"extra.png": PNG})
    assert api.upload(device, manifest, extra).json()["error"] == "unreferenced_file"
    # missing file
    missing = dict(list(files.items())[1:])
    assert api.upload(device, manifest, missing).json()["error"] == "missing_files"
    # duplicate attachment
    parts = [("files", (n, d, "image/png")) for n, d in data] + [("files", data[0])]
    r = api.c.post("/v1/sessions", data={"manifest": json.dumps(manifest)}, files=parts, headers=device)
    assert r.json()["error"] == "duplicate_file"
    # unexpected form field
    r = api.c.post(
        "/v1/sessions", data={"manifest": json.dumps(manifest), "path": "/tmp"}, files=[("files", (n, d, "image/png")) for n, d in data], headers=device
    )
    assert r.json()["error"] == "unexpected_fields"


def test_content_checks(paired):
    api, _, pid, device = paired
    manifest, files = build_manifest(pid)
    name = manifest["frames"][0]["filename"]
    tampered = dict(files, **{name: files[name] + b"x"})
    assert api.upload(device, manifest, tampered).json()["error"] == "sha256_mismatch"

    manifest2, files2 = build_manifest(pid)
    fake = b"MZ not an image"
    manifest2["frames"][0]["sha256"] = hashlib.sha256(fake).hexdigest()
    files2[manifest2["frames"][0]["filename"]] = fake
    assert api.upload(device, manifest2, files2).json()["error"] == "bad_image"


def test_size_limits(tmp_path):
    app = create_app(make_settings(tmp_path, max_file_bytes=40, max_frames=2))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        api = Api(c)
        alice = api.login()
        pid = api.project(alice)
        device = api.pair(alice, pid)
        manifest, files = build_manifest(pid, n_frames=2)
        r = api.upload(device, manifest, files)
        assert r.status_code == 413 and r.json()["error"] == "file_too_large"
        manifest, files = build_manifest(pid, n_frames=3)
        r = api.upload(device, manifest, files)
        assert r.status_code == 413
        # nothing left behind in storage
        leftovers = [p for p in (tmp_path / "data" / "artifacts").rglob("*") if p.is_file()]
        assert leftovers == []


def test_body_size_limit(tmp_path):
    app = create_app(make_settings(tmp_path, max_upload_bytes=1000))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        api = Api(c)
        alice = api.login()
        pid = api.project(alice)
        device = api.pair(alice, pid)
        manifest, files = build_manifest(pid)
        files = {k: v + b"\x00" * 5000 for k, v in files.items()}
        r = api.upload(device, manifest, files)
        assert r.status_code == 413


def test_upload_requires_multipart(paired):
    api, _, _pid, device = paired
    r = api.c.post("/v1/sessions", json={"manifest": "{}"}, headers=device)
    assert r.status_code == 415
