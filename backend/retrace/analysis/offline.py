"""Offline heuristic provider: deterministic stage outputs derived from the
structured evidence in the prompt. Spends no credits. Development/test only;
graphs it produces are labeled `generated_by.provider = offline_heuristic`."""

from __future__ import annotations

import json
from urllib.parse import urlsplit

from .llm import ChatResponse, estimate_prompt_tokens
from .prompts import parse_messages

ASSOCIATION_WINDOW_MS = 3000


def _ax_label(accessibility) -> str | None:
    if isinstance(accessibility, dict):
        for key in ("title", "label", "description", "identifier", "role"):
            v = accessibility.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
    if isinstance(accessibility, str) and accessibility.strip():
        return accessibility.strip()
    return None


def _window(accessibility) -> str | None:
    if isinstance(accessibility, dict):
        for key in ("window_title", "window"):
            v = accessibility.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return None


def workflow(payload: dict) -> dict:
    frames = {f["id"]: f for f in payload.get("frames", [])}
    screen_key: dict[str, str] = {}
    screens = []
    window_for_frame: dict[str, str] = {}
    for i in payload.get("interactions", []):
        w = _window(i.get("accessibility"))
        for ref in (i.get("before_frame_id"), i.get("after_frame_id"), i.get("delayed_frame_id")):
            if ref and w and ref not in window_for_frame:
                window_for_frame[ref] = w

    def screen_for(frame_id):
        if not frame_id or frame_id not in frames:
            return None
        if frame_id not in screen_key:
            key = f"s{len(screens) + 1}"
            screen_key[frame_id] = key
            t = frames[frame_id]["timestamp_ms"] / 1000
            screens.append(
                {"key": key, "label": window_for_frame.get(frame_id) or f"Screen at {t:.1f}s", "evidence_ids": [frame_id]}
            )
        return screen_key[frame_id]

    actions = []
    ambiguities = []
    verbs = {
        "click": "Click",
        "double_click": "Double-click",
        "right_click": "Right-click",
        "other_click": "Click",
        "scroll": "Scroll",
        "key": "Press",
        "text_input": "Type into",
    }
    for idx, i in enumerate(payload.get("interactions", []), start=1):
        kind = i.get("kind", "")
        if kind in ("focus_lost", "focus_regained"):
            if kind == "focus_lost":
                ambiguities.append(f"Target app lost focus at {i['timestamp_ms'] / 1000:.1f}s; capture paused")
            continue
        target = _ax_label(i.get("accessibility")) or ""
        if kind == "key":
            label = f"Press {i.get('key') or 'key'}" + (f" in {target}" if target else "")
        else:
            label = f"{verbs.get(kind, kind.replace('_', ' ').capitalize())} {target}".strip()
        after_ref = i.get("after_frame_id") or i.get("delayed_frame_id")
        before, after = screen_for(i.get("before_frame_id")), screen_for(after_ref)
        refs = (i.get("before_frame_id"), i.get("after_frame_id"), i.get("delayed_frame_id"))
        evidence = [i["id"]] + [f for f in refs if f in frames]
        actions.append({"key": f"a{idx}", "label": label, "from": before, "to": after, "evidence_ids": evidence})
    if not screens and frames:
        first = next(iter(frames))
        screen_for(first)
    return {"screens": screens, "actions": actions, "ambiguities": ambiguities}


def network(payload: dict) -> dict:
    interactions = sorted(
        (i for i in payload.get("interactions", []) if i.get("kind") not in ("focus_lost", "focus_regained")),
        key=lambda i: i["timestamp_ms"],
    )
    api_calls, associations = [], []
    for idx, n in enumerate(payload.get("network", []), start=1):
        path = urlsplit(n["url"]).path or "/"
        key = f"n{idx}"
        api_calls.append({"key": key, "label": f"{n['method'].upper()} {path}", "evidence_ids": [n["id"]]})
        prior = [i for i in interactions if 0 <= n["timestamp_ms"] - i["timestamp_ms"] <= ASSOCIATION_WINDOW_MS]
        if prior:
            i = prior[-1]
            associations.append({"interaction_id": i["id"], "api_call": key, "evidence_ids": [i["id"], n["id"]]})
    return {"api_calls": api_calls, "associations": associations, "ambiguities": []}


class OfflineHeuristicProvider:
    name = "offline_heuristic"

    def chat(self, model: str, messages: list[dict], max_tokens: int, temperature: float) -> ChatResponse:
        stage, payload = parse_messages(messages)
        if stage == "workflow":
            out = workflow(payload)
        elif stage == "network":
            out = network(payload)
        else:  # reconcile / publish: return the draft unchanged
            out = payload.get("draft", {})
        content = json.dumps(out)
        return ChatResponse(content, estimate_prompt_tokens(messages), len(content) // 3, True)
