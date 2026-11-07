import json

from retrace.redaction import REDACTED, redact_body, redact_headers, redact_network_entry, redact_text, redact_url


def test_headers():
    h = redact_headers(
        {
            "Authorization": "Bearer abc.def.ghi",
            "Cookie": "sid=123",
            "Set-Cookie": "session=abc",
            "X-API-Key": "k",
            "X-Custom-Token": "t",
            "Content-Type": "application/json",
            "Accept": "*/*",
            "X-Request-Id": "req-1",
        }
    )
    for k in ("Authorization", "Cookie", "Set-Cookie", "X-API-Key", "X-Custom-Token"):
        assert h[k] == REDACTED
    assert h["Content-Type"] == "application/json"
    assert h["X-Request-Id"] == "req-1"


def test_url_query_userinfo_fragment_path():
    u = redact_url(
        "https://user:pw@api.example.com:8443/v1/users/alice@example.com/orders/550e8400-e29b-41d4-a716-446655440000"
        "?access_token=zzz&page=2&q=ok&sig=abc&x=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sigsigsig#frag"
    )
    assert "user:pw" not in u and "#frag" not in u
    assert "alice@example.com" not in u
    assert "{uuid}" in u
    assert "page=2" in u and "q=ok" in u
    assert "zzz" not in u and "sig=abc" not in u and "eyJ" not in u
    assert u.startswith("https://api.example.com:8443/")


def test_json_body():
    body = redact_body(
        '{"username":"bob","password":"hunter2","nested":{"apiKey":"k","items":[{"card":"4111 1111 1111 1111"}]},"note":"call me at bob@x.io","qty":2}',
        "application/json",
    )
    data = json.loads(body)
    assert data["password"] == REDACTED
    assert data["nested"]["apiKey"] == REDACTED
    assert data["nested"]["items"][0]["card"] == REDACTED
    assert "bob@x.io" not in body
    assert data["qty"] == 2 and data["username"] == "bob"


def test_form_and_text_bodies():
    assert "hunter2" not in redact_body("user=bob&password=hunter2", "application/x-www-form-urlencoded")
    t = redact_text("token nvapi-ABCDEFGHIJKLMNOPQRSTUV and sk-abcdefghijklmnopqrstuvwx and AKIAABCDEFGHIJKLMNOP")
    assert "nvapi-" not in t and "sk-abc" not in t and "AKIA" not in t
    assert redact_body(b"\xff\xfe\x00binary") .startswith("[binary")
    assert len(redact_body("x" * 10000)) <= 4000


def test_network_entry_shape_preserved():
    entry = {
        "id": "1",
        "timestamp_ms": 5,
        "method": "GET",
        "url": "https://h.example/a?token=abc",
        "status": 200,
        "request_headers": {"Authorization": "Basic dXNlcjpwYXNzd29yZA=="},
        "response_headers": {"Set-Cookie": "a=b", "Content-Type": "text/plain"},
        "request_body": None,
        "response_body": "hello",
    }
    out = redact_network_entry(entry)
    assert out["id"] == "1" and out["status"] == 200 and out["method"] == "GET"
    assert out["request_headers"]["Authorization"] == REDACTED
    assert out["response_headers"]["Set-Cookie"] == REDACTED
    assert "abc" not in out["url"]
    assert out["response_body"] == "hello"
