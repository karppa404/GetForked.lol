"""Four-stage bounded analysis: workflow analyst, network analyst,
reconciliation, publisher. Stage results are written incrementally to shared
state; the graph is validated deterministically before it is published."""

from __future__ import annotations

import base64
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, Callable

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from ..config import LLMSettings
from ..graph import EvidenceIndex, GraphValidationError, assert_publishable, normalize_graph
from ..models import Manifest
from ..security import iso, utcnow
from ..state.base import GraphRec, JobRec, SharedState, StageRec
from .llm import BoundedLLM, BudgetExceeded, ChatProvider, GlobalLimiter, LLMError, UsageLedger, extract_json
from .prompts import build_messages

STAGES = ("workflow", "network", "reconcile", "publish")
PIPELINE_NAME = "retrace-4stage-v1"


class _Loose(BaseModel):
    model_config = ConfigDict(extra="ignore")


class ScreenOut(_Loose):
    key: str = Field(max_length=64)
    label: str = Field(default="", max_length=500)
    evidence_ids: list[str] = Field(default_factory=list, max_length=200)


class ActionOut(_Loose):
    key: str = Field(max_length=64)
    label: str = Field(default="", max_length=500)
    from_: str | None = Field(default=None, alias="from")
    to: str | None = None
    evidence_ids: list[str] = Field(default_factory=list, max_length=200)


class WorkflowOut(_Loose):
    screens: list[ScreenOut] = Field(default_factory=list, max_length=300)
    actions: list[ActionOut] = Field(default_factory=list, max_length=1000)
    ambiguities: list[str] = Field(default_factory=list, max_length=100)


class ApiCallOut(_Loose):
    key: str = Field(max_length=64)
    label: str = Field(default="", max_length=500)
    evidence_ids: list[str] = Field(default_factory=list, max_length=200)


class AssociationOut(_Loose):
    interaction_id: str
    api_call: str
    evidence_ids: list[str] = Field(default_factory=list, max_length=50)


class NetworkOut(_Loose):
    api_calls: list[ApiCallOut] = Field(default_factory=list, max_length=500)
    associations: list[AssociationOut] = Field(default_factory=list, max_length=1000)
    ambiguities: list[str] = Field(default_factory=list, max_length=100)


class GraphDraftOut(_Loose):
    nodes: list[dict[str, Any]] = Field(default_factory=list, max_length=400)
    edges: list[dict[str, Any]] = Field(default_factory=list, max_length=800)
    ambiguities: list[Any] = Field(default_factory=list, max_length=100)
    suggestions: list[Any] = Field(default_factory=list, max_length=60)


@dataclass
class PipelineDeps:
    state: SharedState
    provider: ChatProvider
    llm_settings: LLMSettings
    ledger: UsageLedger
    limiter: GlobalLimiter
    load_manifest: Callable[[], Manifest]
    load_frame: Callable[[str], bytes | None]  # frame_id -> bytes
    sleep: Callable[[float], None] | None = None


def _bounded_list(items: list[dict], budget_chars: int) -> tuple[list[dict], bool]:
    out, used = [], 0
    for item in items:
        size = len(json.dumps(item, default=str))
        if used + size > budget_chars:
            return out, True
        out.append(item)
        used += size
    return out, False


def _evidence_payload(manifest: Manifest, max_chars: int) -> dict:
    frames = [
        {"id": str(f.id), "timestamp_ms": f.timestamp_ms, "width": f.width, "height": f.height} for f in manifest.frames
    ]
    interactions = [
        {
            k: v
            for k, v in {
                "id": str(i.id),
                "timestamp_ms": i.timestamp_ms,
                "kind": i.kind,
                "key": i.key,
                "x": i.x,
                "y": i.y,
                "accessibility": i.accessibility,
                "before_frame_id": str(i.before_frame_id) if i.before_frame_id else None,
                "after_frame_id": str(i.after_frame_id) if i.after_frame_id else None,
            }.items()
            if v is not None
        }
        for i in manifest.interactions
    ]
    network = [
        {"id": str(n.id), "timestamp_ms": n.timestamp_ms, "method": n.method, "url": n.url, "status": n.status}
        for n in manifest.network
    ]
    budget = max(1000, max_chars - 4000)
    frames, t1 = _bounded_list(frames, budget // 4)
    interactions, t2 = _bounded_list(interactions, budget // 2)
    network, t3 = _bounded_list(network, budget // 4)
    return {
        "task": manifest.task[:500],
        "app": {"name": manifest.app.name, "bundle_id": manifest.app.bundle_id},
        "duration_ms": manifest.duration_ms,
        "frames": frames,
        "interactions": interactions,
        "network": network,
        "truncated": {"frames": t1, "interactions": t2, "network": t3},
    }


def select_frames(manifest: Manifest, limit: int) -> list[str]:
    referenced: list[str] = []
    for i in manifest.interactions:
        for ref in (i.before_frame_id, i.after_frame_id):
            if ref and str(ref) not in referenced:
                referenced.append(str(ref))
    pool = referenced or [str(f.id) for f in manifest.frames]
    if len(pool) <= limit:
        return pool
    step = len(pool) / limit
    return [pool[int(k * step)] for k in range(limit)]


def mechanical_draft(wf: WorkflowOut, net: NetworkOut | None) -> dict:
    nodes, edges = [], []
    action_for_interaction: dict[str, str] = {}
    for s in wf.screens:
        nodes.append({"id": s.key, "type": "screen", "label": s.label, "evidence_ids": s.evidence_ids})
    for a in wf.actions:
        nodes.append({"id": a.key, "type": "action", "label": a.label, "evidence_ids": a.evidence_ids})
        for e in a.evidence_ids:
            action_for_interaction.setdefault(e, a.key)
        if a.from_:
            edges.append({"source": a.from_, "target": a.key, "label": "", "evidence_ids": a.evidence_ids, "association": "observed"})
        if a.to:
            edges.append({"source": a.key, "target": a.to, "label": "", "evidence_ids": a.evidence_ids, "association": "observed"})
    ambiguities = list(wf.ambiguities)
    if net:
        for c in net.api_calls:
            nodes.append({"id": c.key, "type": "api_call", "label": c.label, "evidence_ids": c.evidence_ids})
        for assoc in net.associations:
            src = action_for_interaction.get(assoc.interaction_id)
            if src:
                edges.append(
                    {"source": src, "target": assoc.api_call, "label": "followed by", "evidence_ids": assoc.evidence_ids, "association": "candidate"}
                )
        ambiguities += net.ambiguities
    return {"nodes": nodes, "edges": edges, "ambiguities": ambiguities, "suggestions": []}


class Pipeline:
    def __init__(self, deps: PipelineDeps, job: JobRec, session_id: str):
        self.deps = deps
        self.job = job
        self.session_id = session_id
        kwargs = {"sleep": deps.sleep} if deps.sleep else {}
        self.llm = BoundedLLM(deps.provider, deps.llm_settings, deps.ledger, deps.limiter, job.job_id, **kwargs)
        self.problems: list[str] = []

    # ---- shared state helpers ----
    def _update_job(self, status: str | None = None, stage: str | None = None, error: str | None = None) -> None:
        j = self.job
        if status:
            j.status = status
        if stage:
            j.stage = stage
        if error is not None:
            j.error = error[:500]
        j.calls_used = self.llm.calls_used
        j.prompt_tokens = self.llm.prompt_tokens
        j.completion_tokens = self.llm.completion_tokens
        j.usage_estimated = self.llm.estimated
        j.updated_at = iso(utcnow())
        self.deps.state.upsert_job(j)

    def _stage(self, stage: str, status: str, summary: dict) -> None:
        text = json.dumps(summary, default=str)
        if len(text) > 60_000:
            text = json.dumps({k: v for k, v in summary.items() if k != "output"} | {"output_truncated": True})
        self.deps.state.record_stage(StageRec(self.job.job_id, stage, status, text, iso(utcnow())))

    def _ask(self, stage: str, payload: dict, schema: type[BaseModel], images: list[str] | None = None) -> BaseModel:
        model = self.deps.llm_settings.model_for(stage) or "unconfigured"
        messages = build_messages(stage, payload, images)
        resp = self.llm.call(stage, model, messages)
        try:
            return schema.model_validate(extract_json(resp.content))
        except (ValueError, ValidationError) as exc:
            # One repair attempt, subject to the same call/token caps.
            repair = messages + [
                {"role": "assistant", "content": resp.content[:4000]},
                {"role": "user", "content": f"Your reply was not valid for the schema ({str(exc)[:300]}). Reply with only the JSON object."},
            ]
            resp2 = self.llm.call(stage, model, repair)
            return schema.model_validate(extract_json(resp2.content))

    # ---- run ----
    def run(self) -> GraphRec | None:
        deps = self.deps
        try:
            manifest = deps.load_manifest()
            index = EvidenceIndex.from_manifest(manifest)
            payload = _evidence_payload(manifest, deps.llm_settings.max_prompt_chars)
            self._update_job(status="running", stage="workflow")

            images: list[str] = []
            if deps.llm_settings.vision_enabled:
                for fid in select_frames(manifest, deps.llm_settings.max_frames_per_job):
                    data = deps.load_frame(fid)
                    if data and len(data) <= deps.llm_settings.max_frame_bytes:
                        mime = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
                        images.append(f"data:{mime};base64,{base64.b64encode(data).decode()}")

            wf_payload = {k: v for k, v in payload.items() if k != "network"}
            run_network = index.capture_status == "captured" and bool(manifest.network)
            net_payload = {
                "task": payload["task"],
                "interactions": [{"id": i["id"], "timestamp_ms": i["timestamp_ms"], "kind": i["kind"]} for i in payload["interactions"]],
                "network": payload["network"],
            }
            with ThreadPoolExecutor(max_workers=2) as pool:
                wf_future = pool.submit(self._ask, "workflow", wf_payload, WorkflowOut, images or None)
                net_future = pool.submit(self._ask, "network", net_payload, NetworkOut) if run_network else None
                wf = wf_future.result()
                self._stage("workflow", "succeeded", {"screens": len(wf.screens), "actions": len(wf.actions), "frames_sent": len(images), "output": wf.model_dump(by_alias=True)})
                net = None
                if net_future is not None:
                    try:
                        net = net_future.result()
                        self._stage("network", "succeeded", {"api_calls": len(net.api_calls), "associations": len(net.associations), "output": net.model_dump()})
                    except BudgetExceeded:
                        raise
                    except (LLMError, ValueError, ValidationError) as exc:
                        self.problems.append(f"network analyst failed: {str(exc)[:200]}")
                        self._stage("network", "failed", {"error": str(exc)[:300]})
                else:
                    reason = "network capture did not run" if index.capture_status != "captured" else "capture ran; no requests observed"
                    self._stage("network", "skipped", {"reason": reason, "capture_status": index.capture_status})

            self._update_job(stage="reconcile")
            draft = mechanical_draft(wf, net)
            pre = normalize_graph(draft, index, self.session_id)
            try:
                reconciled = self._ask("reconcile", {"task": payload["task"], "draft": draft}, GraphDraftOut)
                rec = normalize_graph(reconciled.model_dump(), index, self.session_id)
                if not rec.graph["nodes"] and pre.graph["nodes"]:
                    raise ValueError("reconciliation removed every node")
                self._stage("reconcile", "succeeded", {"problems": rec.problems[:50], "nodes": len(rec.graph["nodes"]), "output": rec.graph})
            except BudgetExceeded:
                raise
            except (LLMError, ValueError, ValidationError) as exc:
                self.problems.append(f"reconciliation failed; used mechanical draft: {str(exc)[:200]}")
                rec = pre
                self._stage("reconcile", "fallback", {"error": str(exc)[:300], "problems": pre.problems[:50]})

            self._update_job(stage="publish")
            final = rec
            try:
                published = self._ask("publish", {"draft": rec.graph, "problems": rec.problems[:50]}, GraphDraftOut)
                candidate = normalize_graph(published.model_dump(), index, self.session_id)
                assert_publishable(candidate.graph, index)
                if not candidate.graph["nodes"] and rec.graph["nodes"]:
                    raise ValueError("publisher removed every node")
                final = candidate
                self._stage("publish", "succeeded", {"problems": candidate.problems[:50]})
            except BudgetExceeded as exc:
                self.problems.append(f"publisher skipped: {exc}")
                self._stage("publish", "skipped", {"reason": str(exc)})
            except (LLMError, ValueError, ValidationError, GraphValidationError) as exc:
                self.problems.append(f"publisher output rejected; published validated reconciliation: {str(exc)[:200]}")
                self._stage("publish", "fallback", {"error": str(exc)[:300]})

            graph = final.graph
            graph["ambiguities"] = (graph["ambiguities"] + [p for p in self.problems if p])[:50]
            assert_publishable(graph, index)
            return self._publish(graph)
        except BudgetExceeded as exc:
            self._update_job(status="failed", error=f"budget_stop: {exc}")
            return None
        except GraphValidationError as exc:
            self._update_job(status="failed", error=f"graph_validation_failed: {exc}")
            return None
        except (LLMError, ValueError, ValidationError) as exc:
            self._update_job(status="failed", error=f"analysis_failed: {str(exc)[:300]}")
            return None
        except Exception as exc:  # pragma: no cover - defensive
            self._update_job(status="failed", error=f"internal_error: {type(exc).__name__}")
            raise

    def _publish(self, graph: dict) -> GraphRec:
        state = self.deps.state
        version = max([g.version for g in state.list_graphs(self.session_id)] or [0]) + 1
        graph["graph_version"] = version
        graph["generated_at"] = iso(utcnow())
        graph["generated_by"] = {
            "pipeline": PIPELINE_NAME,
            "provider": self.deps.provider.name,
            "job_id": self.job.job_id,
            "models": {s: self.deps.llm_settings.model_for(s) for s in STAGES},
        }
        rec = GraphRec(
            graph_id=f"{self.session_id}:v{version}:{uuid.uuid4().hex[:8]}",
            session_id=self.session_id,
            job_id=self.job.job_id,
            version=version,
            network_status=graph["network_status"],
            node_count=len(graph["nodes"]),
            edge_count=len(graph["edges"]),
            graph_json=json.dumps(graph, separators=(",", ":")),
            published_at=graph["generated_at"],
        )
        state.publish_graph(rec)
        self._update_job(status="succeeded", stage="done")
        return rec
