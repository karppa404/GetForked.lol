"""Graph v1: deterministic validation and normalization before publishing.

Rules enforced here (independent of what any model returns):
- every node and edge references at least one evidence ID captured in the
  session; unknown IDs are removed and elements left without evidence dropped;
- screens need a frame, actions an interaction, api_call nodes a network entry;
- edges reference existing nodes; edges touching an api_call node are always
  `association: "candidate"` (passive capture only shows timing, not causation);
- workflow edges are `observed` only if they cite interaction evidence;
- `network_status` is computed from the capture status: `not_captured` when no
  capture ran (api nodes are then impossible), `none_observed` only when
  capture ran and found nothing, otherwise `observed`;
- modernization suggestions are moved to `suggestions` and never appear as
  observed nodes or edges;
- node IDs are deterministic (`<type>:<primary evidence id>`) so human
  corrections keyed by element ID survive agent reruns.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from typing import Any

NODE_TYPES = {"screen", "action", "api_call"}
REQUIRED_KIND = {"screen": "frame", "action": "interaction", "api_call": "network"}
SUGGESTION_TYPES = {"suggestion", "proposed", "modernization", "recommendation"}
NETWORK_STATUSES = {"observed", "none_observed", "not_captured"}
MAX_NODES = 200
MAX_EDGES = 400
MAX_LABEL = 200
MAX_AMBIGUITIES = 50
MAX_SUGGESTIONS = 30
ELEMENT_ID_RE = re.compile(r"^(screen|action|api_call|edge):[A-Za-z0-9:_>-]{1,160}$")


class GraphValidationError(ValueError):
    def __init__(self, problems: list[str]):
        super().__init__("; ".join(problems[:10]))
        self.problems = problems


@dataclass
class EvidenceIndex:
    kinds: dict[str, str]  # evidence_id -> frame | interaction | network
    timestamps: dict[str, int]
    capture_status: str  # captured | not_captured

    @classmethod
    def from_manifest(cls, manifest) -> "EvidenceIndex":
        kinds: dict[str, str] = {}
        ts: dict[str, int] = {}
        for kind, items in (("frame", manifest.frames), ("interaction", manifest.interactions), ("network", manifest.network)):
            for item in items:
                kinds[str(item.id)] = kind
                ts[str(item.id)] = item.timestamp_ms
        return cls(kinds, ts, manifest.capture_status)


@dataclass
class NormalizeResult:
    graph: dict
    problems: list[str] = field(default_factory=list)


def clean_label(value: Any, fallback: str) -> str:
    text = "".join(ch for ch in str(value or "") if ch.isprintable())
    text = " ".join(text.split())[:MAX_LABEL]
    return text or fallback


def edge_id(source: str, target: str) -> str:
    return "edge:" + hashlib.sha256(f"{source}>{target}".encode()).hexdigest()[:20]


def normalize_graph(draft: dict, index: EvidenceIndex, session_id: str) -> NormalizeResult:
    problems: list[str] = []
    nodes_in = draft.get("nodes") if isinstance(draft.get("nodes"), list) else []
    edges_in = draft.get("edges") if isinstance(draft.get("edges"), list) else []
    suggestions: list[dict] = []
    for s in draft.get("suggestions") or []:
        if isinstance(s, dict):
            suggestions.append(s)
        elif isinstance(s, str):
            suggestions.append({"label": s})

    id_map: dict[str, str] = {}
    nodes: dict[str, dict] = {}
    for raw in nodes_in[: MAX_NODES * 2]:
        if not isinstance(raw, dict):
            continue
        ntype = str(raw.get("type", "")).lower()
        raw_id = str(raw.get("id", ""))
        if ntype in SUGGESTION_TYPES:
            suggestions.append({"label": raw.get("label"), "rationale": raw.get("rationale")})
            problems.append(f"node {raw_id!r} was a suggestion; moved to suggestions")
            continue
        if ntype not in NODE_TYPES:
            problems.append(f"node {raw_id!r} has unsupported type {ntype!r}; dropped")
            continue
        evidence = [str(e) for e in (raw.get("evidence_ids") or []) if isinstance(e, (str, int))]
        valid = [e for e in dict.fromkeys(evidence) if e in index.kinds]
        if len(valid) != len(evidence):
            problems.append(f"node {raw_id!r}: removed {len(evidence) - len(valid)} unknown evidence id(s)")
        required = REQUIRED_KIND[ntype]
        primary = sorted((e for e in valid if index.kinds[e] == required), key=lambda e: (index.timestamps[e], e))
        if not primary:
            problems.append(f"node {raw_id!r} ({ntype}) has no {required} evidence; dropped")
            continue
        if ntype == "api_call" and index.capture_status != "captured":
            problems.append(f"node {raw_id!r}: network was not captured; dropped")
            continue
        nid = f"{ntype}:{primary[0]}"
        if raw_id:
            id_map[raw_id] = nid
        if nid in nodes:
            merged = list(dict.fromkeys(nodes[nid]["evidence_ids"] + valid))
            nodes[nid]["evidence_ids"] = merged
            continue
        nodes[nid] = {
            "id": nid,
            "type": ntype,
            "label": clean_label(raw.get("label"), f"Untitled {ntype.replace('_', ' ')}"),
            "evidence_ids": valid,
        }
    if len(nodes) > MAX_NODES:
        problems.append(f"node cap {MAX_NODES} reached; truncated")
        nodes = dict(list(nodes.items())[:MAX_NODES])

    edges: dict[str, dict] = {}
    for raw in edges_in[: MAX_EDGES * 2]:
        if not isinstance(raw, dict):
            continue
        src = id_map.get(str(raw.get("source", "")), str(raw.get("source", "")))
        tgt = id_map.get(str(raw.get("target", "")), str(raw.get("target", "")))
        label_hint = raw.get("id") or f"{raw.get('source')}->{raw.get('target')}"
        if src not in nodes or tgt not in nodes:
            problems.append(f"edge {label_hint!r} references unknown node; dropped")
            continue
        if src == tgt:
            problems.append(f"edge {label_hint!r} is a self loop; dropped")
            continue
        evidence = [str(e) for e in (raw.get("evidence_ids") or []) if isinstance(e, (str, int))]
        valid = [e for e in dict.fromkeys(evidence) if e in index.kinds]
        if len(valid) != len(evidence):
            problems.append(f"edge {label_hint!r}: removed {len(evidence) - len(valid)} unknown evidence id(s)")
        if not valid:
            problems.append(f"edge {label_hint!r} has no valid evidence; dropped")
            continue
        touches_api = "api_call" in (nodes[src]["type"], nodes[tgt]["type"])
        requested = str(raw.get("association", "candidate"))
        if touches_api:
            association, basis = "candidate", "timing"
            if requested == "observed":
                problems.append(f"edge {label_hint!r}: API association downgraded to candidate (timing only)")
        elif any(index.kinds[e] == "interaction" for e in valid):
            association, basis = ("observed" if requested != "candidate" else "candidate"), "interaction"
        else:
            association, basis = "candidate", "inferred"
            if requested == "observed":
                problems.append(f"edge {label_hint!r}: no interaction evidence; marked candidate")
        eid = edge_id(src, tgt)
        if eid in edges:
            edges[eid]["evidence_ids"] = list(dict.fromkeys(edges[eid]["evidence_ids"] + valid))
            continue
        edges[eid] = {
            "id": eid,
            "source": src,
            "target": tgt,
            "label": clean_label(raw.get("label"), ""),
            "evidence_ids": valid,
            "association": association,
            "basis": basis,
        }
    if len(edges) > MAX_EDGES:
        problems.append(f"edge cap {MAX_EDGES} reached; truncated")
        edges = dict(list(edges.items())[:MAX_EDGES])

    has_api = any(n["type"] == "api_call" for n in nodes.values())
    if index.capture_status != "captured":
        network_status = "not_captured"
    else:
        network_status = "observed" if has_api else "none_observed"
    api_linked = set()
    for e in edges.values():
        for a, b in ((e["source"], e["target"]), (e["target"], e["source"])):
            if nodes[a]["type"] == "action" and nodes[b]["type"] == "api_call":
                api_linked.add(a)
    for n in nodes.values():
        if n["type"] == "action":
            if index.capture_status != "captured":
                n["network_status"] = "not_captured"
            else:
                n["network_status"] = "observed" if n["id"] in api_linked else "none_observed"

    ambiguities = [clean_label(a, "") for a in (draft.get("ambiguities") or []) if a]
    ambiguities = [a for a in ambiguities if a][:MAX_AMBIGUITIES]

    out_suggestions = []
    all_ids = set(nodes) | set(edges)
    for i, s in enumerate(suggestions[:MAX_SUGGESTIONS]):
        label = clean_label(s.get("label"), "")
        if not label:
            continue
        related = [id_map.get(str(r), str(r)) for r in (s.get("related_element_ids") or [])]
        out_suggestions.append(
            {
                "id": f"suggestion:{i + 1}",
                "kind": "suggestion",
                "label": label,
                "rationale": clean_label(s.get("rationale"), "")[:MAX_LABEL],
                "related_element_ids": [r for r in related if r in all_ids],
            }
        )

    graph = {
        "schema_version": 1,
        "session_id": session_id,
        "nodes": list(nodes.values()),
        "edges": list(edges.values()),
        "network_status": network_status,
        "ambiguities": ambiguities,
        "suggestions": out_suggestions,
    }
    return NormalizeResult(graph, problems)


def assert_publishable(graph: dict, index: EvidenceIndex) -> None:
    """Strict final check. Raises GraphValidationError on any violation."""
    problems: list[str] = []
    if graph.get("schema_version") != 1:
        problems.append("schema_version must be 1")
    if graph.get("network_status") not in NETWORK_STATUSES:
        problems.append("invalid network_status")
    node_ids = set()
    types = {}
    for n in graph.get("nodes", []):
        nid = n.get("id")
        if not isinstance(nid, str) or not ELEMENT_ID_RE.match(nid) or nid in node_ids:
            problems.append(f"bad or duplicate node id {nid!r}")
        node_ids.add(nid)
        types[nid] = n.get("type")
        if n.get("type") not in NODE_TYPES:
            problems.append(f"node {nid}: bad type")
        ev = n.get("evidence_ids") or []
        if not ev or any(e not in index.kinds for e in ev):
            problems.append(f"node {nid}: evidence must be non-empty and captured")
        elif not any(index.kinds[e] == REQUIRED_KIND.get(n.get("type"), "") for e in ev):
            problems.append(f"node {nid}: missing {REQUIRED_KIND.get(n.get('type'))} evidence")
    for e in graph.get("edges", []):
        eid = e.get("id")
        if e.get("source") not in node_ids or e.get("target") not in node_ids:
            problems.append(f"edge {eid}: unknown endpoint")
        ev = e.get("evidence_ids") or []
        if not ev or any(x not in index.kinds for x in ev):
            problems.append(f"edge {eid}: evidence must be non-empty and captured")
        if e.get("association") not in {"observed", "candidate"}:
            problems.append(f"edge {eid}: bad association")
        if "api_call" in (types.get(e.get("source")), types.get(e.get("target"))) and e.get("association") != "candidate":
            problems.append(f"edge {eid}: API association must be candidate")
    has_api = any(t == "api_call" for t in types.values())
    status = graph.get("network_status")
    if index.capture_status != "captured" and (status != "not_captured" or has_api):
        problems.append("network not captured: status must be not_captured with no api nodes")
    if index.capture_status == "captured" and status == "not_captured":
        problems.append("network was captured: status cannot be not_captured")
    if status == "none_observed" and has_api:
        problems.append("none_observed with api nodes")
    for s in graph.get("suggestions", []):
        if s.get("kind") != "suggestion" or "association" in s:
            problems.append("suggestions must be kind=suggestion without association")
    if problems:
        raise GraphValidationError(problems)


def apply_corrections(graph: dict, corrections: list) -> dict:
    """Overlay human label corrections. Agent labels are kept as `agent_label`.
    Corrections whose element no longer exists are reported, never deleted."""
    by_id = {c.element_id: c for c in corrections}
    out = {**graph, "nodes": [], "edges": []}
    seen = set()
    for kind in ("nodes", "edges"):
        for el in graph.get(kind, []):
            el = dict(el)
            c = by_id.get(el["id"])
            if c:
                seen.add(el["id"])
                el["agent_label"] = el.get("label", "")
                el["label"] = c.label
                el["corrected"] = True
            out[kind].append(el)
    out["corrections"] = [
        {"element_id": c.element_id, "label": c.label, "updated_at": c.updated_at, "applied": c.element_id in seen}
        for c in corrections
    ]
    return out
