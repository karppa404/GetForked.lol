from datetime import timedelta

from fastapi.testclient import TestClient

from retrace.app import create_app
from retrace.security import iso, utcnow

from .conftest import Api, make_settings


def _start(api, headers, pid):
    p = api.c.post("/v1/pairings", json={"project_id": pid}, headers=headers)
    assert p.status_code == 201
    body = p.json()
    assert set(body) == {"pairing_id", "code", "expires_at"}
    return body


def test_full_pairing_flow_and_replay(api):
    alice = api.login()
    pid = api.project(alice)
    p = _start(api, alice, pid)

    claim = api.c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Studio Mac"})
    assert claim.status_code == 201
    c = claim.json()
    assert c["status"] == "pending" and "device_token" not in c

    # code is single use
    again = api.c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Attacker"})
    assert again.status_code == 400

    # browser sees the pending claim with its device name
    view = api.c.get(f"/v1/pairings/{p['pairing_id']}", headers=alice).json()
    assert view["claims"] == [{"claim_id": c["claim_id"], "device_name": "Studio Mac", "status": "pending"}]
    assert view["expires_at"] == p["expires_at"]

    # pending poll never returns a credential
    r = api.c.post(f"/v1/pairings/claims/{c['claim_id']}/poll", json={"claim_secret": c["claim_secret"]})
    assert r.status_code == 200 and r.json()["status"] == "pending" and "device_token" not in r.json()

    # wrong secret is indistinguishable from unknown claim
    r = api.c.post(f"/v1/pairings/claims/{c['claim_id']}/poll", json={"claim_secret": "rtc_wrong-secret-value"})
    assert r.status_code == 404

    assert api.c.post(f"/v1/pairings/{p['pairing_id']}/approve", json={"claim_id": c["claim_id"]}, headers=alice).status_code == 200
    assert api.c.post(f"/v1/pairings/{p['pairing_id']}/approve", json={"claim_id": c["claim_id"]}, headers=alice).status_code == 409

    # wrong secret still gets nothing after approval
    r = api.c.post(f"/v1/pairings/claims/{c['claim_id']}/poll", json={"claim_secret": "rtc_wrong-secret-value"})
    assert r.status_code == 404

    r = api.c.post(f"/v1/pairings/claims/{c['claim_id']}/poll", json={"claim_secret": c["claim_secret"]})
    body = r.json()
    assert body["status"] == "approved" and body["project_id"] == pid and body["device_token"].startswith("rtd_")

    # replaying the poll never issues a second credential
    r = api.c.post(f"/v1/pairings/claims/{c['claim_id']}/poll", json={"claim_secret": c["claim_secret"]})
    assert r.status_code == 410 and r.json() == {"status": "consumed"}

    me = api.c.get("/v1/devices/me", headers={"Authorization": f"Bearer {body['device_token']}"})
    assert me.status_code == 200 and me.json()["device_name"] == "Studio Mac"


def test_only_owner_can_view_or_approve(api):
    alice, bob = api.login("alice@example.com"), api.login("bob@example.com")
    pid = api.project(alice)
    p = _start(api, alice, pid)
    c = api.c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Mac"}).json()
    assert api.c.get(f"/v1/pairings/{p['pairing_id']}", headers=bob).status_code == 404
    assert api.c.post(f"/v1/pairings/{p['pairing_id']}/approve", json={"claim_id": c["claim_id"]}, headers=bob).status_code == 404
    # claim id from a different pairing is rejected
    p2 = _start(api, alice, pid)
    assert api.c.post(f"/v1/pairings/{p2['pairing_id']}/approve", json={"claim_id": c["claim_id"]}, headers=alice).status_code == 404


def test_rejected_claim_gets_no_token(api):
    alice = api.login()
    pid = api.project(alice)
    p = _start(api, alice, pid)
    c = api.c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Mac"}).json()
    assert api.c.post(f"/v1/pairings/{p['pairing_id']}/reject", json={"claim_id": c["claim_id"]}, headers=alice).json()["status"] == "rejected"
    r = api.c.post(f"/v1/pairings/claims/{c['claim_id']}/poll", json={"claim_secret": c["claim_secret"]})
    assert r.status_code == 403 and "device_token" not in r.json()


def test_expired_code_cannot_be_claimed(tmp_path):
    app = create_app(make_settings(tmp_path, pairing_ttl_s=-1))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        api = Api(c)
        alice = api.login()
        pid = api.project(alice)
        p = _start(api, alice, pid)
        assert c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Mac"}).status_code == 400
        assert c.get(f"/v1/pairings/{p['pairing_id']}", headers=alice).json()["status"] == "expired"


def test_claim_expiry_blocks_approval(tmp_path):
    app = create_app(make_settings(tmp_path, claim_ttl_s=-1))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        api = Api(c)
        alice = api.login()
        pid = api.project(alice)
        p = _start(api, alice, pid)
        claim = c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Mac"}).json()
        assert c.get(f"/v1/pairings/{p['pairing_id']}", headers=alice).json()["claims"][0]["status"] == "expired"
        assert c.post(f"/v1/pairings/{p['pairing_id']}/approve", json={"claim_id": claim["claim_id"]}, headers=alice).status_code == 410
        r = c.post(f"/v1/pairings/claims/{claim['claim_id']}/poll", json={"claim_secret": claim["claim_secret"]})
        assert r.status_code == 410 and r.json()["status"] == "expired"


def test_poll_is_rate_limited_and_bounded(tmp_path):
    app = create_app(make_settings(tmp_path, poll_min_interval_s=30.0, poll_max_count=2))
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        api = Api(c)
        alice = api.login()
        pid = api.project(alice)
        p = _start(api, alice, pid)
        claim = c.post("/v1/pairings/claim", json={"code": p["code"], "device_name": "Mac"}).json()
        url = f"/v1/pairings/claims/{claim['claim_id']}/poll"
        assert c.post(url, json={"claim_secret": claim["claim_secret"]}).status_code == 200
        r = c.post(url, json={"claim_secret": claim["claim_secret"]})
        assert r.status_code == 429 and "retry-after" in r.headers
        # exceed max polls: rewind last_poll_at so interval passes
        services = app.state.services
        for _ in range(2):
            with services.auth.db.tx() as conn:
                conn.execute("UPDATE claims SET last_poll_at=?", (iso(utcnow() - timedelta(seconds=60)),))
            last = c.post(url, json={"claim_secret": claim["claim_secret"]})
        assert last.status_code == 410 and last.json()["status"] == "expired"


def test_claim_endpoint_rate_limited(api):
    codes = [api.c.post("/v1/pairings/claim", json={"code": "ZZZZ-ZZZZ", "device_name": "x"}).status_code for _ in range(12)]
    assert codes[:10] == [400] * 10
    assert 429 in codes[10:]


def test_pairing_code_normalization(api):
    alice = api.login()
    pid = api.project(alice)
    p = _start(api, alice, pid)
    sloppy = p["code"].lower().replace("-", " ")
    assert api.c.post("/v1/pairings/claim", json={"code": sloppy, "device_name": "Mac"}).status_code == 201
