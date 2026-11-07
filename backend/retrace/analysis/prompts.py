"""Stage prompts. Inputs are passed as a JSON block after the INPUT_JSON marker
so the offline provider (and tests) can read the same structured payload."""

from __future__ import annotations

import json

INPUT_MARKER = "INPUT_JSON:"
STAGE_MARKER = "RETRACE_STAGE:"

COMMON = (
    "You are part of Retrace, which documents the activity a person performed in one desktop app while they worked. "
    "You analyze captured evidence only; you never operate the application. "
    "Describe only activity the evidence shows; never guess the person's goal, task or intent. "
    "Every element you output MUST cite evidence_ids copied exactly from the input. "
    "Do not invent evidence IDs, screens, endpoints or causality. Passive capture shows timing, not causation: "
    "API associations are candidates. Never present a modernization idea as observed; put ideas in suggestions. "
    "Reply with a single JSON object and nothing else."
)

WORKFLOW = (
    "Stage 1 (workflow analyst). From frames and interactions, identify the distinct screens and the user "
    "actions that move between them. Output schema: "
    '{"screens":[{"key":"s1","label":"Order form","evidence_ids":["<frame id>"]}],'
    '"actions":[{"key":"a1","label":"Click Save","from":"s1","to":"s2","evidence_ids":["<interaction id>","<frame id>"]}],'
    '"ambiguities":["..."]}. Each screen cites >=1 frame id; each action cites its interaction id.'
)

NETWORK = (
    "Stage 2 (network analyst). From sanitized network entries and interaction timestamps, describe the API calls "
    "and which interactions they plausibly follow in time. Output schema: "
    '{"api_calls":[{"key":"n1","label":"POST /api/orders","evidence_ids":["<network id>"]}],'
    '"associations":[{"interaction_id":"<interaction id>","api_call":"n1","evidence_ids":["<interaction id>","<network id>"]}],'
    '"ambiguities":["..."]}. Associations are timing-based candidates.'
)

RECONCILE = (
    "Stage 3 (reconciliation). Merge the workflow and network analyses into one graph. You receive a mechanical draft; "
    "merge duplicate screens, fix labels, and keep only relationships supported by cited evidence. Output schema: "
    '{"nodes":[{"id":"...","type":"screen|action|api_call","label":"...","evidence_ids":[...]}],'
    '"edges":[{"source":"<node id>","target":"<node id>","label":"...","evidence_ids":[...],"association":"observed|candidate"}],'
    '"ambiguities":["..."],"suggestions":[{"label":"...","rationale":"...","related_element_ids":[...]}]}'
)

PUBLISH = (
    "Stage 4 (publisher). You receive a validated draft graph and the validator's problems. Produce the final graph "
    "in the same schema with concise, developer-facing labels. Do not add elements without evidence. Keep "
    "API edges as candidate. Put modernization ideas only in suggestions."
)

STAGE_TEXT = {"workflow": WORKFLOW, "network": NETWORK, "reconcile": RECONCILE, "publish": PUBLISH}


def build_messages(stage: str, payload: dict, images: list[str] | None = None) -> list[dict]:
    system = f"{COMMON}\n{STAGE_TEXT[stage]}\n{STAGE_MARKER}{stage}"
    text = f"{INPUT_MARKER}\n{json.dumps(payload, separators=(',', ':'), default=str)}"
    if images:
        content: list[dict] | str = [{"type": "text", "text": text}] + [
            {"type": "image_url", "image_url": {"url": url}} for url in images
        ]
    else:
        content = text
    return [{"role": "system", "content": system}, {"role": "user", "content": content}]


def parse_messages(messages: list[dict]) -> tuple[str, dict]:
    stage = messages[0]["content"].rsplit(STAGE_MARKER, 1)[1].strip()
    for m in messages[1:]:
        content = m["content"]
        if isinstance(content, list):
            content = next((p["text"] for p in content if p.get("type") == "text"), "")
        if m.get("role") == "user" and INPUT_MARKER in content:
            return stage, json.loads(content.split(INPUT_MARKER, 1)[1])
    raise ValueError("no input payload in messages")
