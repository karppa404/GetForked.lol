"""SpacetimeDB shared-state client.

Unit tests use a mock transport. The live test runs only when
RETRACE_TEST_SPACETIME_URI, RETRACE_TEST_SPACETIME_DATABASE and
RETRACE_TEST_SPACETIME_TOKEN_FILE point at a disposable database published
from spacetimedb/ (see backend/README.md)."""

import json
import os
import uuid
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from retrace.app import create_app
from retrace.state.base import CorrectionRec, GraphRec, JobRec, ProjectRec, SessionRec, StateUnavailable
from retrace.state.spacetime import SpacetimeState, decode_sql_rows

from .conftest import Api, build_manifest, make_settings

SQL_JOB = [
    {
        "schema": {
            "elements": [
                {"name": {"some": "job_id"}, "algebraic_type": {"String": []}},
                {"name": {"some": "error"}, "algebraic_type": {"Sum": {"variants": [
                    {"name": {"some": "some"}, "algebraic_type": {"String": []}},
                    {"name": {"some": "none"}, "algebraic_type": {"Product": {"elements": []}}}]}}},
            ]
        },
        "rows": [["j1", [1, []]], ["j2", [0, "boom"]]],
    }
]


def test_decode_options():
    assert decode_sql_rows(SQL_JOB) == [{"job_id": "j1", "error": None}, {"job_id": "j2", "error": "boom"}]


def test_reducer_payloads_and_escaping():
    seen = []

    def handler(request: httpx.Request):
        seen.append((request.url.path, request.content.decode(), request.headers["authorization"]))
        if request.url.path.endswith("/sql"):
            return httpx.Response(200, json=[{"schema": {"elements": []}, "rows": []}])
        return httpx.Response(200)

    st = SpacetimeState("http://stdb.test", "retrace", "owner-token", transport=httpx.MockTransport(handler))
    st.upsert_job(JobRec("j", "s", "queued", "queued", None, 0, 0, 0, False, "t", "t"))
    st.grant_viewer("p", "AB" * 32, "u")
    st.get_project("x' OR '1'='1")
    path, body, auth = seen[0]
    assert path == "/v1/database/retrace/call/upsert_job" and auth == "Bearer owner-token"
    assert json.loads(body)["error"] == {"none": []}
    assert json.loads(seen[1][1])["viewer"] == {"__identity__": "0x" + "ab" * 32}
    assert seen[2][1] == "SELECT * FROM project WHERE project_id = 'x'' OR ''1''=''1'"
    with pytest.raises(ValueError):
        st.grant_viewer("p", "not-an-identity", "u")


def test_unreachable_server_reports_not_ready_and_503(tmp_path):
    def handler(request):
        raise httpx.ConnectError("refused")

    st = SpacetimeState("http://stdb.test", "retrace", "tok", transport=httpx.MockTransport(handler))
    status = st.status()
    assert status["ready"] is False and status["backend"] == "spacetimedb"
    with pytest.raises(StateUnavailable):
        st.list_projects("u")
    app = create_app(make_settings(tmp_path), state=st)
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        health = c.get("/health").json()
        assert health["status"] == "degraded" and health["state"]["ready"] is False
        h = Api(c).login()
        r = c.get("/v1/projects", headers=h)
        assert r.status_code == 503 and r.json()["error"] == "state_unavailable"


LIVE = all(os.environ.get(k) for k in ("RETRACE_TEST_SPACETIME_URI", "RETRACE_TEST_SPACETIME_DATABASE", "RETRACE_TEST_SPACETIME_TOKEN_FILE"))


def _live_state():
    token = Path(os.environ["RETRACE_TEST_SPACETIME_TOKEN_FILE"]).read_text().strip()
    return SpacetimeState(os.environ["RETRACE_TEST_SPACETIME_URI"], os.environ["RETRACE_TEST_SPACETIME_DATABASE"], token)


@pytest.mark.skipif(not LIVE, reason="no disposable SpacetimeDB configured")
def test_live_roundtrip_and_privacy():
    st = _live_state()
    assert st.status()["ready"] is True
    pid, sid, uid = str(uuid.uuid4()), str(uuid.uuid4()), f"usr_{uuid.uuid4().hex}"
    st.upsert_project(ProjectRec(pid, "Live", uid, "2026-11-07T00:00:00Z"))
    st.upsert_session(SessionRec(sid, pid, "uploaded", "App", "com.x", "task", "2026-11-07T00:00:00Z", 10, 1, 1, 0, "not_captured", "t", "d"))
    st.upsert_job(JobRec("job-" + sid, sid, "failed", "publish", "boom", 1, 2, 3, True, "t", "t"))
    st.publish_graph(GraphRec(f"{sid}:v1", sid, "job-" + sid, 1, "not_captured", 0, 0, "{}", "t"))
    st.set_correction(CorrectionRec(f"{sid}:screen:a", sid, "screen:a", "Label", uid, "t"))
    st.set_board_url(sid, "https://www.figma.com/board/x/y", uid, "t")
    assert st.get_project(pid).name == "Live"
    assert st.get_session(sid).network_status == "not_captured"
    assert st.list_jobs(sid)[0].error == "boom" and st.list_jobs(sid)[0].usage_estimated is True
    assert [g.version for g in st.list_graphs(sid)] == [1]
    assert st.list_corrections(sid)[0].label == "Label"
    assert st.get_board_url(sid) == "https://www.figma.com/board/x/y"
    with pytest.raises(ValueError):  # graph versions are append-only
        st.publish_graph(GraphRec(f"{sid}:v1", sid, "job", 1, "not_captured", 0, 0, "{}", "t"))

    # an anonymous identity cannot read private tables or write via reducers
    anon = httpx.post(f"{st.uri}/v1/identity").json()
    other = SpacetimeState(st.uri, st.database, anon["token"])
    with pytest.raises(StateUnavailable):
        other.get_project(pid)
    with pytest.raises(ValueError):
        other.upsert_project(ProjectRec(str(uuid.uuid4()), "Evil", uid, "t"))
    # its per-viewer view is empty until the backend grants it, then shows only that project
    view = lambda: httpx.post(f"{st.uri}/v1/database/{st.database}/sql", content=b"SELECT * FROM my_sessions",
                              headers={"Authorization": f"Bearer {anon['token']}"}).json()[0]["rows"]
    assert view() == []
    st.grant_viewer(pid, anon["identity"], uid)
    assert [r[0] for r in view()] == [sid]
    st.revoke_viewer(pid, anon["identity"])
    assert view() == []


@pytest.mark.skipif(not LIVE, reason="no disposable SpacetimeDB configured")
def test_live_api_end_to_end(tmp_path):
    app = create_app(make_settings(tmp_path), state=_live_state())
    with TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1)) as c:
        api = Api(c)
        alice = api.login()
        assert c.get("/health").json()["state"] == {"backend": "spacetimedb", "label": "spacetimedb", "ready": True, "realtime": "views"}
        pid = api.project(alice)
        device = api.pair(alice, pid)
        m, f = build_manifest(pid)
        assert api.upload(device, m, f).status_code == 201
        assert c.post(f"/v1/sessions/{m['id']}/analyze", headers=alice).status_code == 202
        g = c.get(f"/v1/sessions/{m['id']}/graph", headers=alice).json()
        node = g["nodes"][0]["id"]
        assert c.put(f"/v1/sessions/{m['id']}/corrections/{node}", json={"label": "Fixed"}, headers=alice).status_code == 200
        assert c.post(f"/v1/sessions/{m['id']}/analyze", headers=alice, json={"rerun": True}).status_code == 202
        g2 = c.get(f"/v1/sessions/{m['id']}/graph", headers=alice).json()
        assert g2["graph_version"] == 2 and next(n for n in g2["nodes"] if n["id"] == node)["label"] == "Fixed"
        rt = c.get("/v1/realtime", headers=alice).json()
        assert rt["backend"] == "spacetimedb" and "my_corrections" in rt["views"]
