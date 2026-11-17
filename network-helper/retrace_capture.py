"""mitmproxy addon: record sanitized network evidence for a Retrace session.

    mitmdump --listen-host 127.0.0.1 -p 8899 -s network-helper/retrace_capture.py \
        --set retrace_out=./capture.jsonl --set retrace_hosts=api.example.com

This addon never changes system proxy settings or certificate trust. You
configure the target app (or a per-app proxy) yourself and install/trust the
mitmproxy CA yourself, and remove it afterwards. Every entry is redacted
before it is written (auth/cookie headers, secret-looking query values and
path segments, emails, JSON/form secrets). Bodies are omitted unless
retrace_bodies=true, and then redacted and capped at 4000 characters.
Screenshot privacy review in the recorder is still mandatory.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from retrace.redaction import redact_network_entry  # noqa: E402

MAX_ENTRIES = 2000

# Page assets are not API evidence; with retrace_skip_static (default) they are not recorded.
_STATIC_EXT = (".js", ".mjs", ".css", ".map", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg", ".ico",
               ".woff", ".woff2", ".ttf", ".otf", ".mp3", ".mp4", ".m4a", ".ogg", ".webm", ".wasm")
_STATIC_DEST = {"script", "style", "image", "font", "audio", "video", "track", "manifest"}
_STATIC_TYPES = ("image/", "font/", "audio/", "video/", "text/css", "text/javascript", "application/javascript",
                 "application/wasm")


def _header(headers, name: str) -> str:
    for k, v in headers or []:
        if str(k).lower() == name:
            return str(v)
    return ""


def is_static(url: str, req_headers, resp_headers) -> bool:
    """True for scripts, styles, images, fonts and media (by fetch destination, type or extension)."""
    if _header(req_headers, "sec-fetch-dest").lower() in _STATIC_DEST:
        return True
    ctype = _header(resp_headers, "content-type").lower()
    if ctype.startswith(_STATIC_TYPES):
        return True
    path = url.split("?", 1)[0].split("#", 1)[0].lower()
    return path.endswith(_STATIC_EXT)


def effective_url(url: str, status, resp_headers) -> str:
    """A WebSocket upgrade is recorded once, as ws(s)://; its frames are never recorded."""
    if status == 101 and _header(resp_headers, "upgrade").lower() == "websocket":
        if url.startswith("https://"):
            return "wss://" + url[len("https://"):]
        if url.startswith("http://"):
            return "ws://" + url[len("http://"):]
    return url


def host_allowed(host: str, allowlist: list[str]) -> bool:
    if not allowlist:
        return True
    host = host.lower()
    return any(host == h or host.endswith("." + h) for h in allowlist)


def entry_from_parts(method, url, status, req_headers, resp_headers, req_body, resp_body, started_epoch_ms, include_bodies) -> dict:
    raw = {
        "id": str(uuid.uuid4()),
        "captured_at_ms": int(started_epoch_ms),
        "method": method.upper()[:16],
        "url": url,
        "status": status,
        "request_headers": dict(req_headers or {}),
        "response_headers": dict(resp_headers or {}),
        "request_body": req_body if include_bodies else None,
        "response_body": resp_body if include_bodies else None,
    }
    return redact_network_entry(raw)


class RetraceCapture:
    def __init__(self):
        self.count = 0
        self.out = None
        self.hosts: list[str] = []
        self.bodies = False
        self.skip_static = True

    def load(self, loader):
        loader.add_option("retrace_out", str, "retrace-capture.jsonl", "JSONL output file")
        loader.add_option("retrace_hosts", str, "", "comma-separated host allowlist (empty = all)")
        loader.add_option("retrace_bodies", bool, False, "include redacted bodies")
        loader.add_option("retrace_skip_static", bool, True, "skip scripts, styles, images, fonts and media")

    def configure(self, updated):
        from mitmproxy import ctx

        if self.out is None or "retrace_out" in updated:
            if self.out:
                self.out.close()
            fd = os.open(Path(ctx.options.retrace_out), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            self.out = os.fdopen(fd, "a")
        self.hosts = [h.strip().lower() for h in ctx.options.retrace_hosts.split(",") if h.strip()]
        self.bodies = ctx.options.retrace_bodies
        self.skip_static = ctx.options.retrace_skip_static

    def response(self, flow):
        if self.out is None or self.count >= MAX_ENTRIES:
            return
        req, resp = flow.request, flow.response
        if not host_allowed(req.pretty_host, self.hosts):
            return
        req_headers = list(req.headers.items())
        resp_headers = list(resp.headers.items()) if resp else []
        if self.skip_static and is_static(req.pretty_url, req_headers, resp_headers):
            return
        status = resp.status_code if resp else None
        started = (req.timestamp_start or time.time()) * 1000
        entry = entry_from_parts(
            req.method,
            effective_url(req.pretty_url, status, resp_headers),
            status,
            req_headers,
            resp_headers,
            req.get_text(strict=False) if self.bodies else None,
            resp.get_text(strict=False) if (self.bodies and resp) else None,
            started,
            self.bodies,
        )
        self.out.write(json.dumps(entry) + "\n")
        self.out.flush()
        self.count += 1

    def done(self):
        if self.out:
            self.out.close()


addons = [RetraceCapture()]
