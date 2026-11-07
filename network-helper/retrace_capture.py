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

    def load(self, loader):
        loader.add_option("retrace_out", str, "retrace-capture.jsonl", "JSONL output file")
        loader.add_option("retrace_hosts", str, "", "comma-separated host allowlist (empty = all)")
        loader.add_option("retrace_bodies", bool, False, "include redacted bodies")

    def configure(self, updated):
        from mitmproxy import ctx

        path = Path(ctx.options.retrace_out)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.out = os.fdopen(fd, "a")
        self.hosts = [h.strip().lower() for h in ctx.options.retrace_hosts.split(",") if h.strip()]
        self.bodies = ctx.options.retrace_bodies

    def response(self, flow):
        if self.out is None or self.count >= MAX_ENTRIES:
            return
        req, resp = flow.request, flow.response
        if not host_allowed(req.pretty_host, self.hosts):
            return
        started = (req.timestamp_start or time.time()) * 1000
        entry = entry_from_parts(
            req.method,
            req.pretty_url,
            resp.status_code if resp else None,
            req.headers.items(),
            resp.headers.items() if resp else [],
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
