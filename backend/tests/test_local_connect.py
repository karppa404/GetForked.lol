from fastapi.testclient import TestClient

from retrace.app import create_app

from .conftest import build_manifest, make_settings

URL = "/v1/local/connect"


def test_connect_issues_device_for_shared_local_workspace(api, client):
    r = client.post(URL, json={"device_name": "  Lab Mac "})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["device_token"].startswith("rtd_") and body["project_name"] == "Local workspace"
    assert body["api_base_url"] == "http://127.0.0.1:8000"
    device = {"Authorization": f"Bearer {body['device_token']}"}
    me = client.get("/v1/devices/me", headers=device).json()
    assert me["device_id"] == body["device_id"] and me["device_name"] == "Lab Mac" and me["project_id"] == body["project_id"]

    # Second connect reuses the same project; the dashboard's developer sign-in sees it.
    again = client.post(URL, json={"device_name": "Lab Mac"}).json()
    assert again["project_id"] == body["project_id"] and again["device_token"] != body["device_token"]
    user = api.login("dev@localhost")
    projects = client.get("/v1/projects", headers=user).json()["projects"]
    assert [p["id"] for p in projects] == [body["project_id"]]

    # Existing upload flow works with the issued credential.
    manifest, files = build_manifest(body["project_id"])
    up = api.upload(device, manifest, files)
    assert up.status_code == 201, up.text


def test_connect_allows_loopback_origin(client):
    assert client.post(URL, json={"device_name": "M"}, headers={"Origin": "http://localhost:3000"}).status_code == 201


def test_connect_rejects_foreign_origin_host_and_proxy(client):
    for headers in (
        {"Origin": "https://evil.example"},
        {"Origin": "null"},
        {"Host": "retrace.example.com"},
        {"X-Forwarded-For": "198.51.100.1"},
        {"Forwarded": "for=198.51.100.1"},
    ):
        r = client.post(URL, json={"device_name": "M"}, headers=headers)
        assert r.status_code == 403, headers
        assert "device_token" not in r.text


def test_connect_rejects_non_loopback_peer(app):
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("203.0.113.9", 4000)) as c:
        r = c.post(URL, json={"device_name": "M"})
        assert r.status_code == 403 and "device_token" not in r.text


def test_connect_disabled_without_dev_auth(tmp_path):
    app = create_app(make_settings(tmp_path, dev_auth_enabled=False))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        assert c.post(URL, json={"device_name": "M"}).status_code == 404


def test_connect_validates_body(client):
    assert client.post(URL, json={"device_name": "  "}).status_code == 422
    assert client.post(URL, json={"device_name": "M", "extra": 1}).status_code == 422
    assert client.post(URL, content="device_name=M", headers={"Content-Type": "application/x-www-form-urlencoded"}).status_code == 422
