#!/usr/bin/env python3
"""Probe the configured OpenAI-compatible model endpoint (Nemotron on Brev/NIM/vLLM).

Default mode spends nothing: it lists models via GET /models and checks that every
configured stage model ID is served. `--chat` sends ONE completion capped at
`--max-tokens` (default 8) and is refused unless `--allow-spend` is also given.

Output never contains the API key or response bodies; only status codes, model IDs,
latency and token usage. Reads the same RETRACE_LLM_* variables as the API.

    uv run python scripts/probe_model_endpoint.py
    uv run python scripts/probe_model_endpoint.py --chat --allow-spend
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import httpx  # noqa: E402

from retrace.config import ConfigError, Settings  # noqa: E402
from retrace.security import mask_secret  # noqa: E402

STAGES = ("workflow", "network", "reconcile", "publish")


def masked_url(url: str) -> str:
    p = urlsplit(url)
    host = p.hostname or "?"
    if p.port:
        host = f"{host}:{p.port}"
    return urlunsplit((p.scheme, host, p.path, "", ""))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chat", action="store_true", help="send one tiny chat completion")
    ap.add_argument("--allow-spend", action="store_true", help="required with --chat; acknowledges a billable call")
    ap.add_argument("--max-tokens", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=20.0)
    args = ap.parse_args()

    try:
        llm = Settings.from_env().llm
    except ConfigError as exc:
        print(f"config error: {exc}")
        return 2
    print("endpoint:", masked_url(llm.base_url) if llm.base_url else "<unset RETRACE_LLM_BASE_URL>")
    print("api key: ", mask_secret(llm.api_key), "(keyless loopback allowed)" if llm.keyless_allowed else "")
    for s in STAGES:
        print(f"model[{s}]:", llm.model_for(s) or "<unset>")
    if not llm.base_url:
        return 2

    headers = {"Accept": "application/json"}
    if llm.api_key:
        headers["Authorization"] = f"Bearer {llm.api_key}"
    client = httpx.Client(base_url=llm.base_url.rstrip("/"), headers=headers, timeout=args.timeout, follow_redirects=False)

    ok = True
    t0 = time.monotonic()
    try:
        r = client.get("/models")
    except httpx.HTTPError as exc:
        print(f"GET /models: transport error {type(exc).__name__}")
        return 1
    ms = int((time.monotonic() - t0) * 1000)
    ctype = r.headers.get("content-type", "")
    print(f"GET /models: HTTP {r.status_code} in {ms} ms ({ctype.split(';')[0] or 'no content-type'})")
    if 300 <= r.status_code < 400:
        print("  redirect: the endpoint likely requires browser auth (Brev tunnel). Use a local port forward instead.")
        return 1
    if r.status_code == 200 and "json" in ctype:
        try:
            served = sorted({m.get("id") for m in r.json().get("data", []) if isinstance(m, dict)} - {None})
        except (ValueError, AttributeError):
            served = []
        print("  served models:", ", ".join(served) or "<none listed>")
        for s in STAGES:
            m = llm.model_for(s)
            if m and served and m not in served:
                ok = False
                print(f"  MISSING: {s} model {m!r} is not served")
    elif r.status_code in (401, 403):
        print("  auth rejected: check the key (value not shown)")
        ok = False
    else:
        print("  unexpected response; /models may be unsupported by this gateway")

    if args.chat:
        if not args.allow_spend:
            print("--chat refused without --allow-spend (it makes one billable call)")
            return 2
        model = llm.model_for("workflow")
        body = {"model": model, "messages": [{"role": "user", "content": "Reply with the word ok."}],
                "max_tokens": max(1, min(args.max_tokens, 32)), "temperature": 0}
        t0 = time.monotonic()
        try:
            r = client.post("/chat/completions", json=body)
        except httpx.HTTPError as exc:
            print(f"POST /chat/completions: transport error {type(exc).__name__}")
            return 1
        ms = int((time.monotonic() - t0) * 1000)
        print(f"POST /chat/completions ({model}): HTTP {r.status_code} in {ms} ms")
        if r.status_code == 200 and "json" in r.headers.get("content-type", ""):
            data = r.json()
            print("  usage:", json.dumps(data.get("usage") or "not reported (budget will use estimates)"))
            content = ((data.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
            print(f"  reply length: {len(content)} chars")
        else:
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
