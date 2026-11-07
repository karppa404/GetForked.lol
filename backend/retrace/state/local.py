"""Local development fallback for shared state: a durable SQLite file.

This is NOT SpacetimeDB. /health reports it as backend `local`, label
`local-dev-sqlite`, realtime `unavailable`. It exists so the API can be
developed and tested without a SpacetimeDB server.
"""

from __future__ import annotations

from dataclasses import astuple, fields
from pathlib import Path

from ..db import SQLiteDB
from .base import CorrectionRec, EvidenceRefRec, GraphRec, JobRec, ProjectRec, SessionRec, StageRec

SCHEMA = """
CREATE TABLE IF NOT EXISTS project (project_id TEXT PRIMARY KEY, name TEXT, owner_user_id TEXT, created_at TEXT);
CREATE INDEX IF NOT EXISTS project_owner ON project(owner_user_id);
CREATE TABLE IF NOT EXISTS session (
  session_id TEXT PRIMARY KEY, project_id TEXT, status TEXT, app_name TEXT, bundle_id TEXT, task TEXT,
  started_at TEXT, duration_ms INTEGER, frame_count INTEGER, interaction_count INTEGER, network_count INTEGER,
  network_capture TEXT, uploaded_at TEXT, uploaded_by_device TEXT);
CREATE INDEX IF NOT EXISTS session_project ON session(project_id);
CREATE TABLE IF NOT EXISTS evidence_ref (evidence_id TEXT PRIMARY KEY, session_id TEXT, kind TEXT,
  timestamp_ms INTEGER, artifact_key TEXT, summary TEXT);
CREATE INDEX IF NOT EXISTS evidence_session ON evidence_ref(session_id);
CREATE TABLE IF NOT EXISTS job (job_id TEXT PRIMARY KEY, session_id TEXT, status TEXT, stage TEXT, error TEXT,
  calls_used INTEGER, prompt_tokens INTEGER, completion_tokens INTEGER, usage_estimated INTEGER,
  created_at TEXT, updated_at TEXT);
CREATE INDEX IF NOT EXISTS job_session ON job(session_id);
CREATE TABLE IF NOT EXISTS job_stage (job_id TEXT, stage TEXT, status TEXT, summary_json TEXT, updated_at TEXT,
  PRIMARY KEY (job_id, stage));
CREATE TABLE IF NOT EXISTS graph_version (graph_id TEXT PRIMARY KEY, session_id TEXT, job_id TEXT, version INTEGER,
  network_status TEXT, node_count INTEGER, edge_count INTEGER, graph_json TEXT, published_at TEXT);
CREATE INDEX IF NOT EXISTS graph_session ON graph_version(session_id);
CREATE TABLE IF NOT EXISTS correction (correction_id TEXT PRIMARY KEY, session_id TEXT, element_id TEXT, label TEXT,
  author_user_id TEXT, updated_at TEXT);
CREATE INDEX IF NOT EXISTS correction_session ON correction(session_id);
"""


def _cols(cls) -> list[str]:
    return [f.name for f in fields(cls)]


class LocalDevState:
    backend = "local"
    label = "local-dev-sqlite"

    def __init__(self, path: Path):
        self.db = SQLiteDB(path, SCHEMA)

    def status(self) -> dict:
        return {
            "backend": self.backend,
            "label": self.label,
            "ready": True,
            "realtime": "unavailable",
            "note": "Development fallback; not SpacetimeDB. Dashboards must poll the HTTP API.",
        }

    def _upsert(self, table: str, rec) -> None:
        cols = _cols(type(rec))
        values = tuple(int(v) if isinstance(v, bool) else v for v in astuple(rec))
        sql = f"INSERT OR REPLACE INTO {table} ({','.join(cols)}) VALUES ({','.join('?' for _ in cols)})"
        with self.db.tx() as c:
            c.execute(sql, values)

    def _rows(self, cls, sql: str, params: tuple = ()):
        out = []
        for r in self.db.query(sql, params):
            d = {k: r[k] for k in _cols(cls)}
            if cls is JobRec:
                d["usage_estimated"] = bool(d["usage_estimated"])
            out.append(cls(**d))
        return out

    # projects
    def upsert_project(self, p: ProjectRec) -> None:
        self._upsert("project", p)

    def get_project(self, project_id: str) -> ProjectRec | None:
        rows = self._rows(ProjectRec, "SELECT * FROM project WHERE project_id=?", (project_id,))
        return rows[0] if rows else None

    def list_projects(self, owner_user_id: str) -> list[ProjectRec]:
        return self._rows(ProjectRec, "SELECT * FROM project WHERE owner_user_id=? ORDER BY created_at", (owner_user_id,))

    def grant_viewer(self, project_id: str, identity_hex: str, user_id: str) -> None:
        raise NotImplementedError("realtime viewers require the spacetimedb state backend")

    def revoke_viewer(self, project_id: str, identity_hex: str) -> None:
        raise NotImplementedError("realtime viewers require the spacetimedb state backend")

    # sessions
    def upsert_session(self, s: SessionRec) -> None:
        self._upsert("session", s)

    def get_session(self, session_id: str) -> SessionRec | None:
        rows = self._rows(SessionRec, "SELECT * FROM session WHERE session_id=?", (session_id,))
        return rows[0] if rows else None

    def list_sessions(self, project_id: str) -> list[SessionRec]:
        return self._rows(SessionRec, "SELECT * FROM session WHERE project_id=? ORDER BY uploaded_at DESC", (project_id,))

    def add_evidence_refs(self, session_id: str, refs: list[EvidenceRefRec]) -> None:
        with self.db.tx() as c:
            for r in refs:
                c.execute(
                    "INSERT OR REPLACE INTO evidence_ref VALUES (?,?,?,?,?,?)",
                    (r.evidence_id, session_id, r.kind, r.timestamp_ms, r.artifact_key, r.summary),
                )

    def list_evidence_refs(self, session_id: str) -> list[EvidenceRefRec]:
        return self._rows(
            EvidenceRefRec, "SELECT * FROM evidence_ref WHERE session_id=? ORDER BY timestamp_ms", (session_id,)
        )

    # jobs
    def upsert_job(self, j: JobRec) -> None:
        self._upsert("job", j)

    def get_job(self, job_id: str) -> JobRec | None:
        rows = self._rows(JobRec, "SELECT * FROM job WHERE job_id=?", (job_id,))
        return rows[0] if rows else None

    def list_jobs(self, session_id: str) -> list[JobRec]:
        return self._rows(JobRec, "SELECT * FROM job WHERE session_id=? ORDER BY created_at", (session_id,))

    def record_stage(self, s: StageRec) -> None:
        self._upsert("job_stage", s)

    def list_stages(self, job_id: str) -> list[StageRec]:
        return self._rows(StageRec, "SELECT * FROM job_stage WHERE job_id=? ORDER BY updated_at", (job_id,))

    # graphs
    def publish_graph(self, g: GraphRec) -> None:
        if self.db.one("SELECT 1 FROM graph_version WHERE graph_id=?", (g.graph_id,)):
            raise ValueError("graph version exists")
        self._upsert("graph_version", g)

    def list_graphs(self, session_id: str) -> list[GraphRec]:
        return self._rows(GraphRec, "SELECT * FROM graph_version WHERE session_id=? ORDER BY version", (session_id,))

    # corrections
    def set_correction(self, c: CorrectionRec) -> None:
        self._upsert("correction", c)

    def delete_correction(self, correction_id: str) -> None:
        with self.db.tx() as c:
            c.execute("DELETE FROM correction WHERE correction_id=?", (correction_id,))

    def list_corrections(self, session_id: str) -> list[CorrectionRec]:
        return self._rows(CorrectionRec, "SELECT * FROM correction WHERE session_id=? ORDER BY updated_at", (session_id,))
