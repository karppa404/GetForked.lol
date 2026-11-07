"""Backend-private credential store (SQLite).

Holds users, browser access tokens, pairing codes, pairing claims, device
tokens and the LLM usage ledger. Every secret is stored only as a SHA-256 hash
of a high-entropy random value. This data never goes to SpacetimeDB.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path

from .db import SQLiteDB
from .security import hash_secret, iso, new_pairing_code, new_token, parse_iso, secrets_equal, utcnow

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  user_id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  email TEXT NOT NULL,
  name TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(provider, subject)
);
CREATE TABLE IF NOT EXISTS access_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(user_id),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS pairings (
  pairing_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  created_by TEXT NOT NULL REFERENCES users(user_id),
  code_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,            -- open | claimed | cancelled
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS claims (
  claim_id TEXT PRIMARY KEY,
  pairing_id TEXT NOT NULL REFERENCES pairings(pairing_id),
  project_id TEXT NOT NULL,
  device_name TEXT NOT NULL,
  secret_hash TEXT NOT NULL,
  status TEXT NOT NULL,            -- pending | approved | rejected | completed | expired
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  approved_by TEXT,
  poll_count INTEGER NOT NULL DEFAULT 0,
  last_poll_at TEXT,
  device_id TEXT
);
CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  device_name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  claim_id TEXT NOT NULL,
  approved_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS llm_usage (
  usage_id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  model TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  outcome TEXT NOT NULL,
  prompt_tokens INTEGER NOT NULL,
  completion_tokens INTEGER NOT NULL,
  estimated INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
"""


@dataclass
class User:
    user_id: str
    email: str
    name: str | None

    def public(self) -> dict:
        return {"id": self.user_id, "email": self.email, "name": self.name}


@dataclass
class Device:
    device_id: str
    project_id: str
    device_name: str
    created_at: str
    last_used_at: str | None
    revoked_at: str | None

    def public(self) -> dict:
        return {
            "device_id": self.device_id,
            "project_id": self.project_id,
            "device_name": self.device_name,
            "created_at": self.created_at,
            "last_used_at": self.last_used_at,
            "revoked": self.revoked_at is not None,
        }


@dataclass
class PollResult:
    status: str  # not_found | rate_limited | pending | approved | rejected | expired | consumed
    device_token: str | None = None
    project_id: str | None = None
    retry_after_s: float | None = None


class AuthStore:
    def __init__(self, path: Path):
        self.db = SQLiteDB(path, SCHEMA)

    # ---- users & browser access tokens ----
    def upsert_user(self, provider: str, subject: str, email: str, name: str | None) -> User:
        now = iso(utcnow())
        with self.db.tx() as c:
            row = c.execute(
                "SELECT user_id FROM users WHERE provider=? AND subject=?", (provider, subject)
            ).fetchone()
            if row:
                user_id = row["user_id"]
                c.execute("UPDATE users SET email=?, name=? WHERE user_id=?", (email, name, user_id))
            else:
                user_id = f"usr_{uuid.uuid4().hex}"
                c.execute(
                    "INSERT INTO users VALUES (?,?,?,?,?,?)", (user_id, provider, subject, email, name, now)
                )
        return User(user_id, email, name)

    def issue_access_token(self, user_id: str, ttl_s: int) -> tuple[str, str]:
        token = new_token("rta")
        now = utcnow()
        expires = iso(now + timedelta(seconds=ttl_s))
        with self.db.tx() as c:
            c.execute(
                "INSERT INTO access_tokens VALUES (?,?,?,?,NULL)", (hash_secret(token), user_id, iso(now), expires)
            )
        return token, expires

    def user_for_access_token(self, token: str) -> User | None:
        row = self.db.one(
            "SELECT u.user_id, u.email, u.name, t.expires_at, t.revoked_at FROM access_tokens t "
            "JOIN users u ON u.user_id = t.user_id WHERE t.token_hash=?",
            (hash_secret(token),),
        )
        if not row or row["revoked_at"] or parse_iso(row["expires_at"]) <= utcnow():
            return None
        return User(row["user_id"], row["email"], row["name"])

    def revoke_access_token(self, token: str) -> None:
        with self.db.tx() as c:
            c.execute("UPDATE access_tokens SET revoked_at=? WHERE token_hash=?", (iso(utcnow()), hash_secret(token)))

    # ---- pairing ----
    def create_pairing(self, project_id: str, user_id: str, ttl_s: int) -> dict:
        now = utcnow()
        expires = iso(now + timedelta(seconds=ttl_s))
        pairing_id = str(uuid.uuid4())
        for _ in range(5):
            code = new_pairing_code()
            try:
                with self.db.tx() as c:
                    c.execute(
                        "INSERT INTO pairings VALUES (?,?,?,?,?,?,?)",
                        (pairing_id, project_id, user_id, hash_secret(code), "open", iso(now), expires),
                    )
                return {"pairing_id": pairing_id, "code": code, "expires_at": expires}
            except Exception as exc:  # unique collision on code hash; retry
                if "UNIQUE" not in str(exc):
                    raise
        raise RuntimeError("could not allocate pairing code")

    def get_pairing(self, pairing_id: str) -> dict | None:
        row = self.db.one("SELECT * FROM pairings WHERE pairing_id=?", (pairing_id,))
        if not row:
            return None
        claims = self.db.query(
            "SELECT claim_id, device_name, status, expires_at FROM claims WHERE pairing_id=? ORDER BY created_at",
            (pairing_id,),
        )
        now = utcnow()
        out_claims = []
        for c in claims:
            status = c["status"]
            if status == "pending" and parse_iso(c["expires_at"]) <= now:
                status = "expired"
            out_claims.append({"claim_id": c["claim_id"], "device_name": c["device_name"], "status": status})
        status = row["status"]
        if status == "open" and parse_iso(row["expires_at"]) <= now:
            status = "expired"
        return {
            "pairing_id": row["pairing_id"],
            "project_id": row["project_id"],
            "created_by": row["created_by"],
            "status": status,
            "expires_at": row["expires_at"],
            "claims": out_claims,
        }

    def claim(self, code: str, device_name: str, claim_ttl_s: int) -> dict | None:
        """Atomically consume an open, unexpired pairing code. Returns None for
        any unknown, used or expired code (callers must not distinguish)."""
        now = utcnow()
        code_hash = hash_secret(code)
        with self.db.tx() as c:
            row = c.execute("SELECT * FROM pairings WHERE code_hash=?", (code_hash,)).fetchone()
            if not row or row["status"] != "open" or parse_iso(row["expires_at"]) <= now:
                return None
            updated = c.execute(
                "UPDATE pairings SET status='claimed' WHERE pairing_id=? AND status='open'", (row["pairing_id"],)
            ).rowcount
            if updated != 1:
                return None
            claim_id = str(uuid.uuid4())
            claim_secret = new_token("rtc")
            c.execute(
                "INSERT INTO claims (claim_id, pairing_id, project_id, device_name, secret_hash, status, created_at, expires_at)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (
                    claim_id,
                    row["pairing_id"],
                    row["project_id"],
                    device_name,
                    hash_secret(claim_secret),
                    "pending",
                    iso(now),
                    iso(now + timedelta(seconds=claim_ttl_s)),
                ),
            )
        return {"claim_id": claim_id, "claim_secret": claim_secret, "status": "pending"}

    def decide_claim(self, pairing_id: str, claim_id: str, approve: bool, user_id: str) -> str:
        """Returns new status, or an error code: not_found | not_pending | expired."""
        now = utcnow()
        with self.db.tx() as c:
            row = c.execute(
                "SELECT * FROM claims WHERE claim_id=? AND pairing_id=?", (claim_id, pairing_id)
            ).fetchone()
            if not row:
                return "not_found"
            if row["status"] != "pending":
                return "not_pending"
            if parse_iso(row["expires_at"]) <= now:
                c.execute("UPDATE claims SET status='expired' WHERE claim_id=?", (claim_id,))
                return "expired"
            status = "approved" if approve else "rejected"
            c.execute(
                "UPDATE claims SET status=?, approved_at=?, approved_by=? WHERE claim_id=? AND status='pending'",
                (status, iso(now), user_id, claim_id),
            )
            return status

    def poll(self, claim_id: str, claim_secret: str, min_interval_s: float, max_polls: int) -> PollResult:
        now = utcnow()
        with self.db.tx() as c:
            row = c.execute("SELECT * FROM claims WHERE claim_id=?", (claim_id,)).fetchone()
            if not row or not secrets_equal(row["secret_hash"], hash_secret(claim_secret)):
                return PollResult("not_found")
            if row["last_poll_at"]:
                elapsed = (now - parse_iso(row["last_poll_at"])).total_seconds()
                if elapsed < min_interval_s:
                    return PollResult("rate_limited", retry_after_s=round(min_interval_s - elapsed, 3))
            c.execute(
                "UPDATE claims SET poll_count=poll_count+1, last_poll_at=? WHERE claim_id=?", (iso(now), claim_id)
            )
            status = row["status"]
            if status == "pending" and (parse_iso(row["expires_at"]) <= now or row["poll_count"] + 1 > max_polls):
                c.execute("UPDATE claims SET status='expired' WHERE claim_id=?", (claim_id,))
                return PollResult("expired")
            if status == "approved":
                if parse_iso(row["expires_at"]) + timedelta(seconds=600) <= now:
                    c.execute("UPDATE claims SET status='expired' WHERE claim_id=?", (claim_id,))
                    return PollResult("expired")
                token = new_token("rtd")
                device_id = str(uuid.uuid4())
                approver = row["approved_by"] or ""
                c.execute(
                    "INSERT INTO devices VALUES (?,?,?,?,?,?,?,NULL,NULL)",
                    (device_id, row["project_id"], row["device_name"], hash_secret(token), claim_id, approver, iso(now)),
                )
                c.execute(
                    "UPDATE claims SET status='completed', device_id=? WHERE claim_id=? AND status='approved'",
                    (device_id, claim_id),
                )
                return PollResult("approved", device_token=token, project_id=row["project_id"])
            if status == "completed":
                return PollResult("consumed")
            return PollResult(status)

    # ---- devices ----
    def device_for_token(self, token: str) -> Device | None:
        row = self.db.one("SELECT * FROM devices WHERE token_hash=?", (hash_secret(token),))
        if not row or row["revoked_at"]:
            return None
        with self.db.tx() as c:
            c.execute("UPDATE devices SET last_used_at=? WHERE device_id=?", (iso(utcnow()), row["device_id"]))
        return self._device(row)

    def get_device(self, device_id: str) -> Device | None:
        row = self.db.one("SELECT * FROM devices WHERE device_id=?", (device_id,))
        return self._device(row) if row else None

    def list_devices(self, project_id: str) -> list[Device]:
        rows = self.db.query("SELECT * FROM devices WHERE project_id=? ORDER BY created_at", (project_id,))
        return [self._device(r) for r in rows]

    def revoke_device(self, device_id: str) -> None:
        with self.db.tx() as c:
            c.execute(
                "UPDATE devices SET revoked_at=? WHERE device_id=? AND revoked_at IS NULL", (iso(utcnow()), device_id)
            )

    @staticmethod
    def _device(row) -> Device:
        return Device(
            row["device_id"], row["project_id"], row["device_name"], row["created_at"], row["last_used_at"], row["revoked_at"]
        )

    # ---- LLM usage ledger ----
    def record_usage(
        self, job_id: str, stage: str, model: str, attempt: int, outcome: str, prompt: int, completion: int, estimated: bool
    ) -> None:
        with self.db.tx() as c:
            c.execute(
                "INSERT INTO llm_usage (job_id, stage, model, attempt, outcome, prompt_tokens, completion_tokens, estimated, created_at)"
                " VALUES (?,?,?,?,?,?,?,?,?)",
                (job_id, stage, model, attempt, outcome, prompt, completion, int(estimated), iso(utcnow())),
            )

    def usage_totals(self) -> dict:
        row = self.db.one(
            "SELECT COUNT(*) AS calls, COALESCE(SUM(prompt_tokens),0) AS p, COALESCE(SUM(completion_tokens),0) AS c,"
            " COALESCE(MAX(estimated),0) AS est FROM llm_usage"
        )
        return {
            "calls": row["calls"],
            "prompt_tokens": row["p"],
            "completion_tokens": row["c"],
            "includes_estimates": bool(row["est"]),
        }
