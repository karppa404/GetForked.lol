# Retrace network helper (optional)

A small [mitmproxy](https://mitmproxy.org) addon that records **sanitized** HTTP(S)
evidence while you demonstrate a task, plus a converter into the manifest's
`network` array. It is optional: without it the recorder reports
`network_status: "not_captured"`, and the analysis never claims "no network calls".

## Safety model

- The helper **never** changes system proxy settings or certificate trust. You do
  that yourself, for the target app only if possible, and undo it afterwards.
- Redaction runs before anything is written: `Authorization`, `Cookie`,
  `Set-Cookie`, API-key/token/session headers; secret-looking query values and path
  segments (JWTs, long hex/base64 tokens, emails; UUIDs become `{uuid}`); URL userinfo
  and fragments. Bodies are omitted by default; with `retrace_bodies=true` they are
  redacted (sensitive JSON/form keys, token patterns, card-like numbers, emails) and
  capped at 4000 characters. The API re-redacts on ingest.
- Output files are created `0600`. Use a host allowlist so unrelated traffic is never
  recorded. Redaction is heuristic: **review before upload**, and screenshot privacy
  review in the recorder remains mandatory.

## Use

```bash
pipx install mitmproxy            # or: uv tool install mitmproxy
mitmdump --listen-host 127.0.0.1 -p 8899 -s network-helper/retrace_capture.py \
  --set retrace_out=./capture.jsonl --set retrace_hosts=api.example.com
# Point only the target app at 127.0.0.1:8899 and trust the mitmproxy CA yourself
# (see https://docs.mitmproxy.org/stable/concepts-certificates/). Record the task.
python3 network-helper/export_evidence.py capture.jsonl \
  --started-at <manifest started_at> --duration-ms <manifest duration_ms> > network.json
```

Merge `network.json` (`network_status` + `network`) into the session manifest before
review. Apps with certificate pinning will not be captured; report `not_captured`.
Tests: `cd backend && uv run pytest tests/test_network_helper.py`.
