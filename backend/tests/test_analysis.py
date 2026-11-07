"""Analysis pipeline tests. No live model calls: the offline heuristic provider
and an httpx.MockTransport stand in for the Nemotron endpoint."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from retrace.analysis.llm import OpenAICompatibleProvider
from retrace.analysis.prompts import parse_messages
from retrace.app import create_app
from retrace.config import LLMSettings
from retrace.graph import EvidenceIndex, assert_publishable

from .conftest import Api, build_manifest, make_settings

SECRET_KEY = "nvapi-TESTKEY-not-real-0123456789"


def _client(app):
    return TestClient(app, base_url="http://127.0.0.1:8000", client=("127.0.0.1", 1))


def _setup(api, **manifest_kwargs):
    alice = api.login()
    pid = api.project(alice)
    device = api.pair(alice, pid)
    manifest, files = build_manifest(pid, **manifest_kwargs)
    assert api.upload(device, manifest, files).status_code == 201
    return alice, device, manifest


def test_offline_pipeline_end_to_end(api):
    alice, device, manifest = _setup(api)
    sid = manifest["id"]
    r = api.c.post(f"/v1/sessions/{sid}/analyze", headers=device, json={})
    assert r.status_code == 202, r.text
    job_id = r.json()["job_id"]

    detail = api.c.get(f"/v1/sessions/{sid}", headers=alice).json()
    assert detail["id"] == sid and detail["status"] == "analyzed"
    assert detail["job"]["id"] == job_id and detail["job"]["status"] == "succeeded"
    assert [s["name"] for s in detail["job"]["stages"]] == ["workflow", "network", "reconcile", "publish"]
    assert all(s["status"] == "done" for s in detail["job"]["stages"])
    assert detail["frames"][0]["image_url"] == f"/v1/sessions/{sid}/frames/{manifest['frames'][0]['id']}"
    assert len(detail["interactions"]) == 2 and detail["corrections"] == [] and detail["board_url"] is None

    graph = api.c.get(f"/v1/sessions/{sid}/graph", headers=alice).json()
    assert graph == detail["graph"] | {"corrections": []}
    types = {n["type"] for n in graph["nodes"]}
    assert types == {"screen", "action", "api_call"}
    assert graph["network_status"] == "observed"
    assert all(e["association"] == "candidate" for e in graph["edges"] if e["id"] and any(
        n["id"] in (e["source"], e["target"]) and n["type"] == "api_call" for n in graph["nodes"]))
    assert graph["generated_by"]["provider"] == "offline_heuristic"
    index = EvidenceIndex({**{f["id"]: "frame" for f in manifest["frames"]}, **{i["id"]: "interaction" for i in manifest["interactions"]},
                           **{n["id"]: "network" for n in manifest["network"]}}, {}, "captured")
    index.timestamps = {k: 0 for k in index.kinds}
    assert_publishable({k: v for k, v in graph.items() if k != "corrections"}, index)

    # device sees status but not evidence or graph content
    dev_view = api.c.get(f"/v1/sessions/{sid}", headers=device).json()
    assert "graph" not in dev_view and "frames" not in dev_view and dev_view["graph_meta"]["version"] == 1


def test_network_status_from_capture(api):
    alice, device, manifest = _setup(api, network=False)
    sid = manifest["id"]
    api.c.post(f"/v1/sessions/{sid}/analyze", headers=alice)
    g = api.c.get(f"/v1/sessions/{sid}/graph", headers=alice).json()
    assert g["network_status"] == "not_captured"
    assert all(n.get("network_status") == "not_captured" for n in g["nodes"] if n["type"] == "action")
    stages = {s["name"]: s for s in api.c.get(f"/v1/sessions/{sid}", headers=alice).json()["job"]["stages"]}
    assert stages["network"]["status"] == "skipped" and "did not run" in stages["network"]["detail"]

    m2, f2 = build_manifest(manifest["project_id"], network=False, status="none_observed")
    assert api.upload(device, m2, f2).status_code == 201
    api.c.post(f"/v1/sessions/{m2['id']}/analyze", headers=alice)
    g2 = api.c.get(f"/v1/sessions/{m2['id']}/graph", headers=alice).json()
    assert g2["network_status"] == "none_observed"
    assert all(n.get("network_status") == "none_observed" for n in g2["nodes"] if n["type"] == "action")


def test_corrections_survive_reruns(api):
    alice, device, manifest = _setup(api)
    sid = manifest["id"]
    api.c.post(f"/v1/sessions/{sid}/analyze", headers=alice)
    g1 = api.c.get(f"/v1/sessions/{sid}/graph", headers=alice).json()
    screen = next(n for n in g1["nodes"] if n["type"] == "screen")
    edge = g1["edges"][0]
    r = api.c.put(f"/v1/sessions/{sid}/corrections/{screen['id']}", json={"label": "Order entry"}, headers=alice)
    assert r.status_code == 200 and r.json()["label"] == "Order entry"
    api.c.put(f"/v1/sessions/{sid}/corrections/{edge['id']}", json={"label": "submits"}, headers=alice)

    # a plain retry does not start a new job; an explicit rerun does
    again = api.c.post(f"/v1/sessions/{sid}/analyze", headers=alice, json={})
    assert again.status_code == 200 and again.json()["existing"] is True
    rerun = api.c.post(f"/v1/sessions/{sid}/analyze", headers=alice, json={"rerun": True})
    assert rerun.status_code == 202
    g2 = api.c.get(f"/v1/sessions/{sid}/graph", headers=alice).json()
    assert g2["graph_version"] == 2
    node = next(n for n in g2["nodes"] if n["id"] == screen["id"])
    assert node["label"] == "Order entry" and node["agent_label"] == screen["label"] and node["corrected"]
    assert next(e for e in g2["edges"] if e["id"] == edge["id"])["label"] == "submits"
    raw = api.c.get(f"/v1/sessions/{sid}/graph?corrections=false", headers=alice).json()
    assert next(n for n in raw["nodes"] if n["id"] == screen["id"])["label"] == screen["label"]
    assert len(api.c.get(f"/v1/sessions/{sid}", headers=alice).json()["corrections"]) == 2

    # deleting restores the agent label
    assert api.c.delete(f"/v1/sessions/{sid}/corrections/{screen['id']}", headers=alice).status_code == 204
    g3 = api.c.get(f"/v1/sessions/{sid}/graph", headers=alice).json()
    assert next(n for n in g3["nodes"] if n["id"] == screen["id"])["label"] == screen["label"]


def test_correction_authorization_and_validation(api):
    alice, device, manifest = _setup(api)
    sid = manifest["id"]
    api.c.post(f"/v1/sessions/{sid}/analyze", headers=alice)
    node_id = api.c.get(f"/v1/sessions/{sid}/graph", headers=alice).json()["nodes"][0]["id"]
    bob = api.login("bob@example.com")
    assert api.c.put(f"/v1/sessions/{sid}/corrections/{node_id}", json={"label": "x"}, headers=bob).status_code == 404
    assert api.c.put(f"/v1/sessions/{sid}/corrections/{node_id}", json={"label": "x"}, headers=device).status_code == 401
    assert api.c.put(f"/v1/sessions/{sid}/corrections/screen:nope", json={"label": "x"}, headers=alice).status_code == 404
    assert api.c.put(f"/v1/sessions/{sid}/corrections/bad id", json={"label": "x"}, headers=alice).status_code == 400
    assert api.c.put(f"/v1/sessions/{sid}/corrections/{node_id}", json={"label": "   "}, headers=alice).status_code == 422


def test_board_url(api):
    alice, device, manifest = _setup(api)
    sid = manifest["id"]
    url = "https://www.figma.com/board/abc123/Retrace"
    assert api.c.put(f"/v1/sessions/{sid}/board", json={"board_url": url}, headers=alice).json()["board_url"] == url
    assert api.c.get(f"/v1/sessions/{sid}", headers=alice).json()["board_url"] == url
    assert api.c.put(f"/v1/sessions/{sid}/board", json={"board_url": "https://evil.example/figma.com/x"}, headers=alice).status_code == 422
    assert api.c.put(f"/v1/sessions/{sid}/board", json={"board_url": "javascript:alert(1)"}, headers=alice).status_code == 422
    assert api.c.put(f"/v1/sessions/{sid}/board", json={"board_url": url}, headers=device).status_code == 401


# ---------------- mocked OpenAI-compatible endpoint ----------------
class FakeNemotron:
    """Scripted chat-completions server. `script[stage]` is a list of replies:
    a dict (JSON content), a str (raw content) or an int (HTTP status)."""

    def __init__(self, script):
        self.script = {k: list(v) for k, v in script.items()}
        self.calls = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        assert request.headers["authorization"] == f"Bearer {SECRET_KEY}"
        body = json.loads(request.content)
        stage, payload = parse_messages(body["messages"])
        assert "task" not in payload and "never guess" in body["messages"][0]["content"]
        self.calls.append((stage, body["model"], body["max_tokens"]))
        reply = self.script[stage].pop(0) if self.script.get(stage) else {}
        if isinstance(reply, int):
            return httpx.Response(reply, json={"error": "boom"})
        if callable(reply):
            reply = reply(payload)
        content = reply if isinstance(reply, str) else json.dumps(reply)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}], "usage": {"prompt_tokens": 100, "completion_tokens": 50}})


def _llm(**kw):
    base = dict(provider="openai_compatible", base_url="https://gateway.invalid/v1", api_key=SECRET_KEY,
                model_default="nvidia/nemotron-test", max_calls_per_job=8, max_retries=1)
    base.update(kw)
    return LLMSettings(**base)


def _mock_app(tmp_path, fake, **llm_kw):
    provider = OpenAICompatibleProvider("https://gateway.invalid/v1", SECRET_KEY, 5, transport=httpx.MockTransport(fake.handler))
    sleeps = []
    app = create_app(make_settings(tmp_path, llm=_llm(**llm_kw)), provider=provider, sleep=sleeps.append)
    return app, sleeps


def _hostile_workflow(payload):
    frames = [f["id"] for f in payload["frames"]]
    inter = [i["id"] for i in payload["interactions"]]
    return {
        "screens": [{"key": "s1", "label": "Start", "evidence_ids": [frames[0]]}, {"key": "s2", "label": "Invented", "evidence_ids": ["not-real"]}],
        "actions": [{"key": "a1", "label": "Click", "from": "s1", "to": "s2", "evidence_ids": [inter[0]]}],
        "ambiguities": [],
    }


def _hostile_reconcile(payload):
    d = payload["draft"]
    d["edges"].append({"source": "a1", "target": "n1", "label": "causes", "evidence_ids": ["fabricated"], "association": "observed"})
    d["nodes"].append({"id": "x", "type": "suggestion", "label": "Use a REST API"})
    return d


def test_mock_endpoint_outputs_are_validated(tmp_path):
    fake = FakeNemotron({
        "workflow": [_hostile_workflow],
        "network": [lambda p: {"api_calls": [{"key": "n1", "label": "POST /orders", "evidence_ids": [p["network"][0]["id"]]}],
                               "associations": [{"interaction_id": p["interactions"][0]["id"], "api_call": "n1",
                                                 "evidence_ids": [p["interactions"][0]["id"], p["network"][0]["id"]]}]}],
        "reconcile": [_hostile_reconcile],
        "publish": ["this is not json"],
    })
    app, _ = _mock_app(tmp_path, fake)
    with _client(app) as c:
        api = Api(c)
        alice, device, manifest = _setup(api)
        sid = manifest["id"]
        assert c.post(f"/v1/sessions/{sid}/analyze", headers=alice).status_code == 202
        detail = c.get(f"/v1/sessions/{sid}", headers=alice).json()
        assert detail["job"]["status"] == "succeeded", detail["job"]
        g = detail["graph"]
        valid = {f["id"] for f in manifest["frames"]} | {i["id"] for i in manifest["interactions"]} | {n["id"] for n in manifest["network"]}
        for el in g["nodes"] + g["edges"]:
            assert el["evidence_ids"] and set(el["evidence_ids"]) <= valid
        assert not any(n["label"] == "Invented" for n in g["nodes"])
        assert all(n["type"] != "suggestion" for n in g["nodes"])
        assert [s["label"] for s in g["suggestions"]] == ["Use a REST API"]
        for e in g["edges"]:
            if e["target"].startswith("api_call:"):
                assert e["association"] == "candidate"
        messages = " ".join(a["message"] for a in g["ambiguities"])
        assert "publisher output rejected" in messages
        stages = {s["name"]: s["status"] for s in detail["job"]["stages"]}
        assert stages == {"workflow": "done", "network": "done", "reconcile": "done", "publish": "done"}
        # publish attempted twice (original + one repair), all within the call cap
        assert [s for s, _, _ in fake.calls].count("publish") == 2
        assert detail["job"]["usage"]["calls"] == len(fake.calls) <= 8


def test_retries_are_bounded_and_counted(tmp_path):
    fake = FakeNemotron({"workflow": [503, 503, 503]})
    app, sleeps = _mock_app(tmp_path, fake, max_retries=2)
    with _client(app) as c:
        api = Api(c)
        alice, _, manifest = _setup(api, network=False)
        c.post(f"/v1/sessions/{manifest['id']}/analyze", headers=alice)
        job = c.get(f"/v1/sessions/{manifest['id']}", headers=alice).json()["job"]
        assert job["status"] == "failed" and "retries exhausted" in job["error"]
        assert len(fake.calls) == 3 and len(sleeps) == 2
        assert job["usage"]["calls"] == 3


def test_call_cap_triggers_budget_stop(tmp_path):
    fake = FakeNemotron({"workflow": ["nope", "still nope"]})
    app, _ = _mock_app(tmp_path, fake, max_calls_per_job=1)
    with _client(app) as c:
        api = Api(c)
        alice, _, manifest = _setup(api, network=False)
        c.post(f"/v1/sessions/{manifest['id']}/analyze", headers=alice)
        job = c.get(f"/v1/sessions/{manifest['id']}", headers=alice).json()["job"]
        assert job["status"] == "failed" and job["error"].startswith("budget_stop")
        assert len(fake.calls) == 1


def test_global_token_budget_stop_and_ledger(tmp_path):
    fake = FakeNemotron({})
    app, _ = _mock_app(tmp_path, fake, budget_total_tokens=1000, max_output_tokens=900)
    with _client(app) as c:
        api = Api(c)
        alice, _, manifest = _setup(api, network=False)
        c.post(f"/v1/sessions/{manifest['id']}/analyze", headers=alice)
        job = c.get(f"/v1/sessions/{manifest['id']}", headers=alice).json()["job"]
        assert job["error"].startswith("budget_stop") and "global token budget" in job["error"]
        assert fake.calls == []  # stopped before spending anything


def test_dollar_budget_enforced_only_with_prices(tmp_path):
    fake = FakeNemotron({})
    app, _ = _mock_app(tmp_path, fake, price_input_per_mtok=1_000_000.0, price_output_per_mtok=1_000_000.0, budget_usd=1.0)
    with _client(app) as c:
        api = Api(c)
        alice, _, manifest = _setup(api, network=False)
        c.post(f"/v1/sessions/{manifest['id']}/analyze", headers=alice)
        job = c.get(f"/v1/sessions/{manifest['id']}", headers=alice).json()["job"]
        assert "dollar budget" in job["error"] and fake.calls == []
        budget = c.get("/health").json()["analysis"]["budget"]
        assert budget["usd_enforcement"] == "configured_prices"


def test_prompt_and_frame_caps(tmp_path):
    fake = FakeNemotron({})
    app, _ = _mock_app(tmp_path, fake, max_prompt_chars=2000)
    with _client(app) as c:
        api = Api(c)
        alice, device, _ = _setup(api, network=False)
        pid = c.get("/v1/projects", headers=alice).json()["projects"][0]["id"]
        m, f = build_manifest(pid, network=False, n_frames=40)
        assert api.upload(device, m, f).status_code == 201
        c.post(f"/v1/sessions/{m['id']}/analyze", headers=alice)
        for stage, _, max_tokens in fake.calls:
            assert max_tokens == 2048
        # payload was truncated to fit rather than exceeding the cap
        job = c.get(f"/v1/sessions/{m['id']}", headers=alice).json()["job"]
        assert "prompt too large" not in (job["error"] or "")


def test_health_never_exposes_secrets(tmp_path):
    fake = FakeNemotron({})
    app, _ = _mock_app(tmp_path, fake)
    with _client(app) as c:
        text = c.get("/health").text
        assert SECRET_KEY not in text and "nvapi" not in text
        body = c.get("/health").json()
        assert body["analysis"]["api_key_configured"] is True
        assert body["state"]["label"] == "local-dev-sqlite" and body["state"]["realtime"] == "unavailable"
        assert body["analysis"]["budget"]["usd_enforcement"] == "unavailable_prices_not_configured"


def test_analysis_not_configured(tmp_path):
    app = create_app(make_settings(tmp_path, llm=LLMSettings()))
    with _client(app) as c:
        api = Api(c)
        alice, _, manifest = _setup(api)
        r = c.post(f"/v1/sessions/{manifest['id']}/analyze", headers=alice)
        assert r.status_code == 503 and r.json()["error"] == "analysis_not_configured"


def test_concurrent_analyze_requests_create_one_job(tmp_path):
    from concurrent.futures import ThreadPoolExecutor

    settings = make_settings(tmp_path)
    settings.inline_jobs = False
    app = create_app(settings)
    with _client(app) as c:
        api = Api(c)
        alice, device, manifest = _setup(api)
        url = f"/v1/sessions/{manifest['id']}/analyze"
        with ThreadPoolExecutor(8) as pool:
            ids = set(pool.map(lambda _: c.post(url, headers=device, json={}).json()["job_id"], range(8)))
        assert len(ids) == 1
        app.state.services.executor.shutdown(wait=True)


def test_endpoint_configuration_rules():
    from retrace.config import ConfigError, Settings

    keyless = LLMSettings(base_url="http://127.0.0.1:8001/v1", model_default="nvidia/nano-vl")
    assert keyless.configured  # loopback port forward to a self-hosted server
    assert not LLMSettings(base_url="https://gateway.example/v1", model_default="m").configured  # remote needs a key
    with pytest.raises(ConfigError):
        Settings(llm=LLMSettings(base_url="http://10.0.0.5:8000/v1", api_key="k", model_default="m")).validate()


def test_redirect_or_html_login_page_is_not_retried():
    from retrace.analysis.llm import PermanentLLMError

    calls = []

    def handler(request):
        calls.append(request)
        assert "authorization" not in request.headers  # keyless provider sends no header
        if len(calls) == 1:
            return httpx.Response(302, headers={"location": "https://login.brev.dev"})
        return httpx.Response(200, text="<html>login</html>", headers={"content-type": "text/html"})

    p = OpenAICompatibleProvider("http://127.0.0.1:9/v1", None, 5, transport=httpx.MockTransport(handler))
    with pytest.raises(PermanentLLMError, match="redirect"):
        p.chat("m", [{"role": "user", "content": "x"}], 8, 0)
    with pytest.raises(PermanentLLMError, match="non-JSON"):
        p.chat("m", [{"role": "user", "content": "x"}], 8, 0)
    assert len(calls) == 2


def test_inference_api_key_can_be_read_from_a_private_file(tmp_path, monkeypatch):
    from retrace.config import Settings
    key_file = tmp_path / "inference-key"
    key_file.write_text("synthetic-key-not-a-credential\n")
    monkeypatch.delenv("RETRACE_LLM_API_KEY", raising=False)
    monkeypatch.setenv("RETRACE_LLM_API_KEY_FILE", str(key_file))
    settings = Settings.from_env()
    assert settings.llm.api_key == "synthetic-key-not-a-credential"
    assert settings.llm.api_key not in repr(settings.llm)
