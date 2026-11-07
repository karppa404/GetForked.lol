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
