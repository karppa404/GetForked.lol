import pytest
from fastapi.testclient import TestClient

from retrace.app import create_app
from retrace.config import ConfigError, Settings
from retrace.google_auth import GoogleVerifier

from .conftest import Api, build_manifest, make_settings


def test_dev_login_loopback_ok(api):
    headers = api.login()
    r = api.c.get("/v1/auth/me", headers=headers)
    assert r.status_code == 200
    assert r.json()["user"]["email"] == "alice@example.com"


def test_dev_login_rejects_non_loopback_client(app):
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("203.0.113.9", 4000)) as c:
        r = c.post("/v1/auth/dev", json={})
        assert r.status_code == 403
        assert "access_token" not in r.text


def test_dev_login_rejects_forwarded_and_foreign_host(client):
    r = client.post("/v1/auth/dev", json={}, headers={"X-Forwarded-For": "198.51.100.1"})
    assert r.status_code == 403
    r = client.post("/v1/auth/dev", json={}, headers={"Host": "retrace.example.com"})
    assert r.status_code == 403


def test_dev_login_disabled_is_404(tmp_path):
    app = create_app(make_settings(tmp_path, dev_auth_enabled=False))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        assert c.post("/v1/auth/dev", json={}).status_code == 404


def test_insecure_configs_refused():
    with pytest.raises(ConfigError):
        Settings(environment="production", dev_auth_enabled=True, state_backend="spacetimedb").validate()
    with pytest.raises(ConfigError):
        Settings(environment="development", dev_auth_enabled=True, host="0.0.0.0").validate()
    with pytest.raises(ConfigError):
        Settings(environment="production", state_backend="local").validate()


def test_google_not_configured_returns_503(client):
    r = client.post("/v1/auth/google", json={"credential": "x" * 40})
    assert r.status_code == 503
    assert r.json()["error"] == "google_login_not_configured"


def _google_app(tmp_path, claims_for):
    def verify(credential, client_id):
        if credential not in claims_for:
            raise ValueError("bad signature")
        return claims_for[credential]

    verifier = GoogleVerifier("client-123.apps.googleusercontent.com", ["example.com"], verify=verify)
    return create_app(make_settings(tmp_path, dev_auth_enabled=False), google_verifier=verifier)


def test_google_login_verifies_claims(tmp_path):
    base = {"iss": "https://accounts.google.com", "aud": "client-123.apps.googleusercontent.com", "sub": "1", "email": "bob@example.com", "email_verified": True, "name": "Bob"}
    claims = {
        "good-credential-000": base,
        "wrong-audience-000": {**base, "aud": "other"},
        "unverified-email-0": {**base, "email_verified": False},
        "other-domain-00000": {**base, "email": "eve@evil.test"},
    }
    with TestClient(_google_app(tmp_path, claims), client=("127.0.0.1", 1)) as c:
        ok = c.post("/v1/auth/google", json={"credential": "good-credential-000"})
        assert ok.status_code == 200
        body = ok.json()
        assert body["access_token"].startswith("rta_") and body["user"]["email"] == "bob@example.com"
        for bad in ("wrong-audience-000", "unverified-email-0", "other-domain-00000", "forged-credential-0"):
            assert c.post("/v1/auth/google", json={"credential": bad}).status_code == 401


def test_endpoints_require_auth(client):
    assert client.get("/v1/projects").status_code == 401
    assert client.post("/v1/projects", json={"name": "x"}).status_code == 401
    assert client.post("/v1/pairings", json={"project_id": "x"}).status_code == 401
    assert client.get("/v1/projects", headers={"Authorization": "Bearer rta_forged"}).status_code == 401


def test_cross_user_isolation(api):
    alice = api.login("alice@example.com")
    bob = api.login("bob@example.com")
    pid = api.project(alice)
    assert api.c.get(f"/v1/projects/{pid}/sessions", headers=bob).status_code == 404
    assert api.c.post("/v1/pairings", json={"project_id": pid}, headers=bob).status_code == 404
    assert api.c.get("/v1/projects", headers=bob).json()["projects"] == []

    device = api.pair(alice, pid)
    manifest, files = build_manifest(pid)
    assert api.upload(device, manifest, files).status_code == 201
    sid = manifest["id"]
    assert api.c.get(f"/v1/sessions/{sid}", headers=bob).status_code == 404
    assert api.c.post(f"/v1/sessions/{sid}/analyze", headers=bob).status_code == 404
    assert api.c.get(f"/v1/sessions/{sid}/graph", headers=bob).status_code == 404


def test_token_kinds_are_not_interchangeable(api):
    alice = api.login()
    pid = api.project(alice)
    device = api.pair(alice, pid)
    # device token cannot use browser endpoints
    assert api.c.get("/v1/projects", headers=device).status_code == 401
    assert api.c.post("/v1/pairings", json={"project_id": pid}, headers=device).status_code == 401
    # browser token cannot upload as a device
    manifest, files = build_manifest(pid)
    assert api.upload(alice, manifest, files).status_code == 401


def test_device_scoped_to_project_and_revocable(api):
    alice = api.login()
    p1, p2 = api.project(alice, "One"), api.project(alice, "Two")
    d1, d2 = api.pair(alice, p1), api.pair(alice, p2)
    m2, f2 = build_manifest(p2)
    assert api.upload(d2, m2, f2).status_code == 201
    # device for project one cannot read project two's session
    assert api.c.get(f"/v1/sessions/{m2['id']}", headers=d1).status_code == 404
    assert api.c.get(f"/v1/sessions/{m2['id']}", headers=d2).status_code == 200
    # nor upload into project two
    m, f = build_manifest(p2)
    assert api.upload(d1, m, f).status_code == 403

    devices = api.c.get(f"/v1/projects/{p1}/devices", headers=alice).json()["devices"]
    assert len(devices) == 1 and "token" not in str(devices).lower().replace("revoked", "")
    assert api.c.delete(f"/v1/devices/{devices[0]['device_id']}", headers=alice).status_code == 204
    assert api.c.get("/v1/devices/me", headers=d1).status_code == 401


def test_logout_revokes_access_token(api):
    h = api.login()
    assert api.c.post("/v1/auth/logout", headers=h).status_code == 204
    assert api.c.get("/v1/auth/me", headers=h).status_code == 401
