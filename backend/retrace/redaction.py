"""Network evidence redaction.

Dependency-free so the local mitmproxy helper (network-helper/) can import it.
Applied by the helper before evidence leaves the capture step and again by the
API on ingest (defense in depth). Redaction is conservative: when in doubt,
redact. It is not a substitute for the mandatory local screenshot review.
"""

from __future__ import annotations

import json
import re
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

REDACTED = "[REDACTED]"

_SENSITIVE_HEADERS = {
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "api-key",
    "x-auth-token",
    "x-csrf-token",
    "x-xsrf-token",
    "x-amz-security-token",
    "x-goog-api-key",
    "x-session-id",
    "www-authenticate",
}
_SENSITIVE_NAME = re.compile(
    r"(pass(word|wd)?|secret|token|auth|session|sid|cookie|key|signature|sig|credential|jwt|bearer|otp|"
    r"csrf|xsrf|code|ssn|card|cvv|pin|email|phone|account|refresh|access)",
    re.IGNORECASE,
)
_SECRET_PATTERNS = [
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"),  # JWT
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)basic\s+[A-Za-z0-9+/=]{8,}"),
    re.compile(r"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bnvapi-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bxox[abpr]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"),
    re.compile(r"\b[0-9a-fA-F]{32,}\b"),
    re.compile(r"\b(?:\d[ -]?){13,19}\b"),  # card-like digit runs
]
_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_HIGH_ENTROPY = re.compile(r"^[A-Za-z0-9_\-+/=.]{24,}$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def _looks_secret(value: str) -> bool:
    if not value:
        return False
    if _HIGH_ENTROPY.match(value) and any(c.isdigit() for c in value) and any(c.isalpha() for c in value):
        return True
    return any(p.search(value) for p in _SECRET_PATTERNS)


def redact_text(text: str) -> str:
    out = text
    for p in _SECRET_PATTERNS:
        out = p.sub(REDACTED, out)
    return _EMAIL.sub("[REDACTED_EMAIL]", out)


def redact_headers(headers: dict[str, Any] | None) -> dict[str, str] | None:
    if headers is None:
        return None
    out: dict[str, str] = {}
    for name, value in headers.items():
        key = str(name)[:200]
        lower = key.lower()
        sval = str(value)
        if lower in _SENSITIVE_HEADERS or _SENSITIVE_NAME.search(lower.replace("content-", "")):
            # keep harmless, useful metadata headers
            if lower in {"content-type", "content-length", "accept", "user-agent"}:
                out[key] = redact_text(sval)[:500]
            else:
                out[key] = REDACTED
        else:
            out[key] = redact_text(sval)[:500]
    return out


def _redact_path(path: str) -> str:
    segments = path.split("/")
    cleaned = []
    for seg in segments:
        if _UUID.match(seg):
            cleaned.append("{uuid}")
        elif _EMAIL.search(seg):
            cleaned.append("[REDACTED_EMAIL]")
        elif _looks_secret(seg):
            cleaned.append(REDACTED)
        else:
            cleaned.append(seg)
    return "/".join(cleaned)


def redact_url(url: str) -> str:
    try:
        parts = urlsplit(url)
    except ValueError:
        return REDACTED
    netloc = parts.hostname or ""
    if parts.port:
        netloc = f"{netloc}:{parts.port}"
    query = []
    for k, v in parse_qsl(parts.query, keep_blank_values=True):
        if _SENSITIVE_NAME.search(k) or _looks_secret(v) or _EMAIL.search(v):
            query.append((k, REDACTED))
        else:
            query.append((k, v[:200]))
    # userinfo and fragment are always dropped
    return urlunsplit((parts.scheme, netloc, _redact_path(parts.path), urlencode(query, safe="[]"), ""))


def redact_json_value(value: Any, depth: int = 0) -> Any:
    if depth > 20:
        return REDACTED
    if isinstance(value, dict):
        return {
            str(k)[:200]: (REDACTED if _SENSITIVE_NAME.search(str(k)) else redact_json_value(v, depth + 1))
            for k, v in list(value.items())[:200]
        }
    if isinstance(value, list):
        return [redact_json_value(v, depth + 1) for v in value[:200]]
    if isinstance(value, str):
        return REDACTED if _looks_secret(value) else redact_text(value)[:500]
    return value


def redact_body(body: Any, content_type: str | None = None, max_chars: int = 4000) -> str | None:
    """Return a redacted, size-bounded body string, or None if body is empty."""
    if body is None:
        return None
    if isinstance(body, (bytes, bytearray)):
        try:
            body = bytes(body).decode("utf-8")
        except UnicodeDecodeError:
            return f"[binary {len(body)} bytes omitted]"
    if isinstance(body, (dict, list)):
        return json.dumps(redact_json_value(body))[:max_chars]
    text = str(body)
    if not text:
        return None
    ctype = (content_type or "").lower()
    stripped = text.lstrip()
    if "json" in ctype or stripped.startswith(("{", "[")):
        try:
            return json.dumps(redact_json_value(json.loads(text)))[:max_chars]
        except ValueError:
            pass
    if "x-www-form-urlencoded" in ctype:
        pairs = parse_qsl(text, keep_blank_values=True)
        return urlencode(
            [(k, REDACTED if _SENSITIVE_NAME.search(k) or _looks_secret(v) else redact_text(v)) for k, v in pairs]
        )[:max_chars]
    return redact_text(text)[:max_chars]


def redact_network_entry(entry: dict) -> dict:
    """Redact a Network evidence dict in the contract shape."""
    out = dict(entry)
    out["url"] = redact_url(str(entry.get("url", "")))
    out["request_headers"] = redact_headers(entry.get("request_headers"))
    out["response_headers"] = redact_headers(entry.get("response_headers"))
    req_ct = _ctype(entry.get("request_headers"))
    resp_ct = _ctype(entry.get("response_headers"))
    out["request_body"] = redact_body(entry.get("request_body"), req_ct)
    out["response_body"] = redact_body(entry.get("response_body"), resp_ct)
    return out


def _ctype(headers: dict | None) -> str | None:
    if not headers:
        return None
    for k, v in headers.items():
        if str(k).lower() == "content-type":
            return str(v)
    return None
