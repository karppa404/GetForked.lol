"""SpacetimeDB shared state over the HTTP API.

Writes: `POST {uri}/v1/database/{db}/call/{reducer}` with JSON named arguments.
The module's reducers reject callers that are not in `trusted_writer`.
Reads: `POST {uri}/v1/database/{db}/sql` as the database owner; all module
tables are private, so only the owner token (kept by the backend, never sent to
browsers) can read them. Browsers subscribe to per-viewer `my_*` views.
"""

from __future__ import annotations

import re
import threading
import time
from dataclasses import fields
from typing import Any

import httpx

from .base import (
    CorrectionRec,
    EvidenceRefRec,
    GraphRec,
    JobRec,
    ProjectRec,
    SessionRec,
    StageRec,
    StateUnavailable,
)

_IDENTITY_RE = re.compile(r"^(0x)?[0-9a-fA-F]{64}$")

VIEWS = [
    "my_projects",
    "my_sessions",
    "my_evidence_refs",
    "my_jobs",
    "my_job_stages",
    "my_graphs",
    "my_corrections",
]


def sql_str(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _opt(value: str | None) -> dict:
    return {"some": value} if value is not None else {"none": []}


def _decode_value(algebraic_type: dict, value: Any) -> Any:
    # Options arrive as sum values encoded [tag_index, payload].
    if "Sum" in algebraic_type and isinstance(value, list) and len(value) == 2:
        variants = algebraic_type["Sum"]["variants"]
        name = variants[value[0]]["name"].get("some")
        if name == "none":
            return None
        if name == "some":
            return _decode_value(variants[value[0]]["algebraic_type"], value[1])
    return value


def decode_sql_rows(payload: list) -> list[dict]:
    if not payload:
        return []
    stmt = payload[0]
    elements = stmt["schema"]["elements"]
    names = [e["name"].get("some") for e in elements]
    out = []
    for row in stmt["rows"]:
        out.append({n: _decode_value(e["algebraic_type"], v) for n, e, v in zip(names, elements, row)})
    return out


class SpacetimeState:
    backend = "spacetimedb"
    label = "spacetimedb"

    def __init__(self, uri: str, database: str, token: str, timeout_s: float = 10.0, transport: httpx.BaseTransport | None = None):
        self.uri = uri.rstrip("/")
        self.database = database
        self._client = httpx.Client(
            base_url=self.uri,
            timeout=timeout_s,
            headers={"Authorization": f"Bearer {token}"},
            transport=transport,
        )
        self._lock = threading.Lock()
        self._last_error: str | None = None
        self._last_ok: float | None = None

    # ---- transport ----
    def _call(self, reducer: str, args: dict) -> None:
        try:
            r = self._client.post(f"/v1/database/{self.database}/call/{reducer}", json=args)
        except httpx.HTTPError as exc:
            self._fail(f"{reducer}: transport error {type(exc).__name__}")
        if r.status_code >= 400:
            message = r.text[:300]
            if r.status_code >= 500 and "unauthorized" not in message and r.status_code != 530:
                self._fail(f"{reducer}: HTTP {r.status_code}")
            raise ValueError(f"spacetimedb rejected {reducer}: {message}")
        self._ok()

    def _sql(self, query: str) -> list[dict]:
        try:
            r = self._client.post(f"/v1/database/{self.database}/sql", content=query.encode())
        except httpx.HTTPError as exc:
            self._fail(f"sql: transport error {type(exc).__name__}")
        if r.status_code >= 400:
            self._fail(f"sql: HTTP {r.status_code}: {r.text[:200]}")
        self._ok()
        return decode_sql_rows(r.json())

    def _fail(self, msg: str):
        with self._lock:
            self._last_error = msg
        raise StateUnavailable(msg)

    def _ok(self) -> None:
        with self._lock:
            self._last_error = None
            self._last_ok = time.time()

    def status(self) -> dict:
        info = {
            "backend": self.backend,
            "label": self.label,
            "uri": self.uri,
            "database": self.database,
            "realtime": "views",
            "views": VIEWS,
        }
        try:
            r = self._client.get(f"/v1/database/{self.database}")
            if r.status_code != 200:
                return {**info, "ready": False, "error": f"database lookup HTTP {r.status_code}"}
            # Owner check: reading a private table proves our token is the owner.
            self._sql("SELECT * FROM trusted_writer")
            return {**info, "ready": True}
        except (httpx.HTTPError, StateUnavailable) as exc:
            return {**info, "ready": False, "error": str(exc)[:200] or type(exc).__name__}

    def _rows(self, cls, query: str):
        names = {f.name for f in fields(cls)}
        return [cls(**{k: v for k, v in row.items() if k in names}) for row in self._sql(query)]

    # ---- projects ----
    def upsert_project(self, p: ProjectRec) -> None:
        self._call("upsert_project", vars(p))

    def get_project(self, project_id: str) -> ProjectRec | None:
        rows = self._rows(ProjectRec, f"SELECT * FROM project WHERE project_id = {sql_str(project_id)}")
        return rows[0] if rows else None

    def list_projects(self, owner_user_id: str) -> list[ProjectRec]:
        rows = self._rows(ProjectRec, f"SELECT * FROM project WHERE owner_user_id = {sql_str(owner_user_id)}")
        return sorted(rows, key=lambda p: p.created_at)

    def grant_viewer(self, project_id: str, identity_hex: str, user_id: str) -> None:
        if not _IDENTITY_RE.match(identity_hex):
            raise ValueError("invalid identity")
        ident = identity_hex if identity_hex.startswith("0x") else "0x" + identity_hex
        self._call("grant_viewer", {"project_id": project_id, "viewer": {"__identity__": ident.lower()}, "user_id": user_id})

    def revoke_viewer(self, project_id: str, identity_hex: str) -> None:
        if not _IDENTITY_RE.match(identity_hex):
            raise ValueError("invalid identity")
        ident = identity_hex if identity_hex.startswith("0x") else "0x" + identity_hex
        self._call("revoke_viewer", {"project_id": project_id, "viewer": {"__identity__": ident.lower()}})

    # ---- sessions ----
    def upsert_session(self, s: SessionRec) -> None:
        self._call("upsert_session", vars(s))

    def get_session(self, session_id: str) -> SessionRec | None:
        rows = self._rows(SessionRec, f"SELECT * FROM session WHERE session_id = {sql_str(session_id)}")
        return rows[0] if rows else None

    def list_sessions(self, project_id: str) -> list[SessionRec]:
        rows = self._rows(SessionRec, f"SELECT * FROM session WHERE project_id = {sql_str(project_id)}")
        return sorted(rows, key=lambda s: s.uploaded_at, reverse=True)

    def add_evidence_refs(self, session_id: str, refs: list[EvidenceRefRec]) -> None:
        for i in range(0, len(refs), 500):
            chunk = refs[i : i + 500]
            self._call(
                "add_evidence_refs",
                {
                    "session_id": session_id,
                    "refs": [
                        {
                            "evidence_id": r.evidence_id,
                            "kind": r.kind,
                            "timestamp_ms": r.timestamp_ms,
                            "artifact_key": _opt(r.artifact_key),
                            "summary": r.summary,
                        }
                        for r in chunk
                    ],
                },
            )

    def list_evidence_refs(self, session_id: str) -> list[EvidenceRefRec]:
        rows = self._rows(EvidenceRefRec, f"SELECT * FROM evidence_ref WHERE session_id = {sql_str(session_id)}")
        return sorted(rows, key=lambda r: r.timestamp_ms)

    # ---- jobs ----
    def upsert_job(self, j: JobRec) -> None:
        self._call("upsert_job", {**vars(j), "error": _opt(j.error)})

    def get_job(self, job_id: str) -> JobRec | None:
        rows = self._rows(JobRec, f"SELECT * FROM job WHERE job_id = {sql_str(job_id)}")
        return rows[0] if rows else None

    def list_jobs(self, session_id: str) -> list[JobRec]:
        rows = self._rows(JobRec, f"SELECT * FROM job WHERE session_id = {sql_str(session_id)}")
        return sorted(rows, key=lambda j: j.created_at)

    def record_stage(self, s: StageRec) -> None:
        self._call("record_job_stage", vars(s))

    def list_stages(self, job_id: str) -> list[StageRec]:
        rows = self._rows(StageRec, f"SELECT * FROM job_stage WHERE job_id = {sql_str(job_id)}")
        return sorted(rows, key=lambda s: s.updated_at)

    # ---- graphs ----
    def publish_graph(self, g: GraphRec) -> None:
        self._call("publish_graph", vars(g))

    def list_graphs(self, session_id: str) -> list[GraphRec]:
        rows = self._rows(GraphRec, f"SELECT * FROM graph_version WHERE session_id = {sql_str(session_id)}")
        return sorted(rows, key=lambda g: g.version)

    # ---- corrections ----
    def set_correction(self, c: CorrectionRec) -> None:
        self._call("set_correction", vars(c))

    def delete_correction(self, correction_id: str) -> None:
        self._call("delete_correction", {"correction_id": correction_id})

    def list_corrections(self, session_id: str) -> list[CorrectionRec]:
        rows = self._rows(CorrectionRec, f"SELECT * FROM correction WHERE session_id = {sql_str(session_id)}")
        return sorted(rows, key=lambda c: c.updated_at)
