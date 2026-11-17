import importlib.util
import json
from pathlib import Path

HELPER = Path(__file__).resolve().parents[2] / "network-helper"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, HELPER / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_capture_entry_is_redacted_and_bodies_off_by_default():
    cap = _load("retrace_capture")
    e = cap.entry_from_parts(
        "post", "https://u:p@api.example.com/v1/login?session=abc&page=1", 200,
        [("Authorization", "Bearer sk-abcdefghijklmnopqrstuvwx"), ("Cookie", "a=b"), ("Content-Type", "application/json")],
        [("Set-Cookie", "sid=1")], '{"password":"hunter2"}', '{"token":"t"}', 1_000_000, False,
    )
    text = json.dumps(e)
    for secret in ("sk-abc", "a=b", "sid=1", "hunter2", "u:p", "session=abc"):
        assert secret not in text
    assert e["request_body"] is None and e["response_body"] is None and e["method"] == "POST"
    with_bodies = cap.entry_from_parts("POST", "https://h/x", 200, [], [], '{"password":"hunter2","q":1}', None, 0, True)
    assert "hunter2" not in with_bodies["request_body"] and '"q": 1' in with_bodies["request_body"]
    assert cap.host_allowed("v2.api.example.com", ["api.example.com"]) and not cap.host_allowed("evil.com", ["api.example.com"])


def test_export_relative_timestamps_and_status():
    exp = _load("export_evidence")
    start = "2026-11-07T15:00:00.000Z"
    base = 1_794_063_600_000  # 2026-11-07T15:00:00Z in ms
    lines = [
        json.dumps({"id": "b", "captured_at_ms": base + 2500, "method": "GET", "url": "https://h/a?token=x", "status": 200}),
        json.dumps({"id": "a", "captured_at_ms": base + 100, "method": "GET", "url": "https://h/b", "status": 200}),
        json.dumps({"id": "c", "captured_at_ms": base - 5, "method": "GET", "url": "https://h/early"}),
    ]
    out = exp.convert(lines, start, 10_000)
    assert out["network_status"] == "observed"
    assert [(e["id"], e["timestamp_ms"]) for e in out["network"]] == [("a", 100), ("b", 2500)]
    assert "token=x" not in out["network"][1]["url"]
    assert exp.convert([], start, 10)["network_status"] == "none_observed"


def test_static_assets_are_skipped_and_api_calls_kept():
    cap = _load("retrace_capture")
    assert cap.is_static("https://discord.com/assets/bf559b2381f6f5b6.js", [], [])
    assert cap.is_static("https://cdn.discordapp.com/avatars/1/abc", [("Sec-Fetch-Dest", "image")], [])
    assert cap.is_static("https://h/x", [], [("Content-Type", "text/css; charset=utf-8")])
    assert not cap.is_static("https://discord.com/api/v9/users/@me", [("sec-fetch-dest", "empty")],
                             [("content-type", "application/json")])
    assert not cap.is_static("https://discord.com/api/v9/science", [], [])


def test_websocket_upgrade_recorded_as_wss_once():
    cap = _load("retrace_capture")
    url = "https://gateway.discord.gg/?encoding=etf&v=9"
    assert cap.effective_url(url, 101, [("Upgrade", "websocket")]) == "wss://gateway.discord.gg/?encoding=etf&v=9"
    assert cap.effective_url(url, 200, [("Upgrade", "websocket")]) == url
    e = cap.entry_from_parts("GET", cap.effective_url(url, 101, [("upgrade", "websocket")]), 101,
                             [("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="), ("Cookie", "c=1")], [], None, None, 0, False)
    assert e["url"].startswith("wss://") and "c=1" not in json.dumps(e) and "dGhlIHNh" not in json.dumps(e)


def test_discord_fingerprint_headers_and_opaque_ids_redacted():
    from retrace.redaction import REDACTED, redact_headers

    h = redact_headers({
        "authorization": "test-only-authorization",
        "x-super-properties": "eyJvcyI6Ik1hYyBPUyBYIiwiYnJvd3NlciI6IkRpc2NvcmQgQ2xpZW50In0=",
        "x-installation-id": "1438012345678901234.-asFPtYh-iwa2KpMQCwV1JibYYY",
        "x-discord-locale": "en-US",
        "x-discord-timezone": "America/Chicago",
    })
    for k in ("authorization", "x-super-properties", "x-installation-id"):
        assert h[k] == REDACTED, k
    assert h["x-discord-locale"] == "en-US" and h["x-discord-timezone"] == "America/Chicago"
