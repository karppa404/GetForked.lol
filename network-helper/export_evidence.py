#!/usr/bin/env python3
"""Convert a retrace_capture.py JSONL file into manifest `network` evidence.

    python3 network-helper/export_evidence.py capture.jsonl \
        --started-at 2026-11-07T15:00:00.000Z --duration-ms 90000 > network.json

Output: {"network_status": "observed"|"none_observed", "network": [...]} with
timestamp_ms relative to session start, entries outside the session window
dropped, and every entry re-redacted. Only use this when capture actually ran;
if it did not, the recorder must report network_status "not_captured".
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from retrace.redaction import redact_network_entry  # noqa: E402


def convert(lines, started_at: str, duration_ms: int) -> dict:
    start_ms = datetime.fromisoformat(started_at.replace("Z", "+00:00")).timestamp() * 1000
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        raw = json.loads(line)
        ts = int(raw.pop("captured_at_ms") - start_ms)
        if ts < 0 or ts > duration_ms:
            continue
        entry = redact_network_entry({**raw, "timestamp_ms": ts})
        out.append({k: v for k, v in entry.items() if v is not None and v != {}})
    out.sort(key=lambda e: e["timestamp_ms"])
    return {"network_status": "observed" if out else "none_observed", "network": out[:2000]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--started-at", required=True)
    ap.add_argument("--duration-ms", required=True, type=int)
    args = ap.parse_args()
    with open(args.capture) as f:
        json.dump(convert(f, args.started_at, args.duration_ms), sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
