"""Shared state interface: projects, sessions, evidence references, jobs,
incremental stage results, published graph versions and human corrections.

Two implementations exist:
- `SpacetimeState` (backend `spacetimedb`): real SpacetimeDB over HTTP, trusted
  writer reducers + owner SQL reads; dashboards subscribe to per-viewer views.
- `LocalDevState` (backend `local`): a durable SQLite file labeled
  `local-dev-sqlite`. It is a development fallback and never reported as
  SpacetimeDB.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Protocol


class StateUnavailable(RuntimeError):
    """Raised when the configured shared state backend cannot be reached."""


@dataclass
class ProjectRec:
    project_id: str
    name: str
    owner_user_id: str
    created_at: str


@dataclass
class SessionRec:
    session_id: str
    project_id: str
    status: str
    app_name: str
    bundle_id: str
    task: str
    started_at: str
    duration_ms: int
    frame_count: int
    interaction_count: int
    network_count: int
    network_capture: str  # captured | not_captured
    uploaded_at: str
    uploaded_by_device: str


@dataclass
class EvidenceRefRec:
    evidence_id: str
    kind: str  # frame | interaction | network
    timestamp_ms: int
    artifact_key: str | None
    summary: str


@dataclass
class JobRec:
    job_id: str
    session_id: str
    status: str  # queued | running | succeeded | failed
    stage: str
    error: str | None
    calls_used: int
    prompt_tokens: int
    completion_tokens: int
    usage_estimated: bool
    created_at: str
    updated_at: str


@dataclass
class StageRec:
    job_id: str
    stage: str
    status: str
    summary_json: str
    updated_at: str


@dataclass
class GraphRec:
    graph_id: str
    session_id: str
    job_id: str
    version: int
    network_status: str
    node_count: int
    edge_count: int
    graph_json: str
    published_at: str


@dataclass
class CorrectionRec:
    correction_id: str
    session_id: str
    element_id: str
    label: str
    author_user_id: str
    updated_at: str


def to_dict(rec) -> dict:
    return asdict(rec)


class SharedState(Protocol):
    backend: str
    label: str

    def status(self) -> dict: ...

    def upsert_project(self, p: ProjectRec) -> None: ...
    def get_project(self, project_id: str) -> ProjectRec | None: ...
    def list_projects(self, owner_user_id: str) -> list[ProjectRec]: ...
    def grant_viewer(self, project_id: str, identity_hex: str, user_id: str) -> None: ...
    def revoke_viewer(self, project_id: str, identity_hex: str) -> None: ...

    def upsert_session(self, s: SessionRec) -> None: ...
    def get_session(self, session_id: str) -> SessionRec | None: ...
    def list_sessions(self, project_id: str) -> list[SessionRec]: ...
    def add_evidence_refs(self, session_id: str, refs: list[EvidenceRefRec]) -> None: ...
    def list_evidence_refs(self, session_id: str) -> list[EvidenceRefRec]: ...

    def upsert_job(self, j: JobRec) -> None: ...
    def get_job(self, job_id: str) -> JobRec | None: ...
    def list_jobs(self, session_id: str) -> list[JobRec]: ...
    def record_stage(self, s: StageRec) -> None: ...
    def list_stages(self, job_id: str) -> list[StageRec]: ...

    def publish_graph(self, g: GraphRec) -> None: ...
    def list_graphs(self, session_id: str) -> list[GraphRec]: ...

    def set_correction(self, c: CorrectionRec) -> None: ...
    def delete_correction(self, correction_id: str) -> None: ...
    def list_corrections(self, session_id: str) -> list[CorrectionRec]: ...
