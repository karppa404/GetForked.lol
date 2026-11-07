"""Pydantic models for the HTTP v1 contract (docs/INTEGRATION.md)."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Literal, Union
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

SAFE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
ALLOWED_FRAME_EXT = {".png", ".jpg", ".jpeg"}
NAMED_KEY = re.compile(r"^(redacted|[a-z][a-z0-9_]*(\+[a-z0-9_]+)*)$")
_MODIFIERS = {"cmd", "command", "ctrl", "control", "option", "alt", "shift", "fn"}
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_max_length=4096)


# ---------- auth / projects / pairing ----------
class GoogleLoginRequest(Strict):
    credential: str = Field(min_length=10, max_length=8192)


class DevLoginRequest(Strict):
    email: str = Field(default="dev@localhost", max_length=200)
    name: str | None = Field(default="Local Developer", max_length=200)


class ProjectCreate(Strict):
    name: str = Field(min_length=1, max_length=120)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = " ".join(v.split())
        if not v:
            raise ValueError("name must not be blank")
        return v


class PairingCreate(Strict):
    project_id: str = Field(min_length=1, max_length=64)


class PairingClaim(Strict):
    code: str = Field(min_length=4, max_length=32)
    device_name: str = Field(min_length=1, max_length=80)

    @field_validator("device_name")
    @classmethod
    def _clean(cls, v: str) -> str:
        v = "".join(ch for ch in v if ch.isprintable()).strip()
        if not v:
            raise ValueError("device_name must not be blank")
        return v


class PairingApprove(Strict):
    claim_id: UUID


class ClaimPoll(Strict):
    claim_secret: str = Field(min_length=10, max_length=200)


class CorrectionPut(Strict):
    label: str = Field(min_length=1, max_length=300)

    @field_validator("label")
    @classmethod
    def _clean(cls, v: str) -> str:
        v = " ".join("".join(ch for ch in v if ch.isprintable()).split())
        if not v:
            raise ValueError("label must not be blank")
        return v


class RealtimeViewer(Strict):
    identity: str = Field(pattern=r"^(0x)?[0-9a-fA-F]{64}$")


# ---------- session manifest ----------
class AppInfo(Strict):
    name: str = Field(min_length=1, max_length=200)
    bundle_id: str = Field(min_length=1, max_length=200)
    pid: int = Field(ge=0, le=2**31)


AccessibilityValue = Union[str, int, float, bool, None]


class Interaction(Strict):
    id: UUID
    timestamp_ms: int = Field(ge=0)
    kind: str = Field(min_length=1, max_length=40, pattern=r"^[a-z][a-z_]*$")
    x: float | None = None
    y: float | None = None
    key: str | None = Field(default=None, max_length=60)
    scroll_dx: float | None = None
    scroll_dy: float | None = None
    accessibility: dict[str, AccessibilityValue] | str | None = None
    before_frame_id: UUID | None = None
    after_frame_id: UUID | None = None

    @field_validator("key")
    @classmethod
    def _named_key(cls, v: str | None) -> str | None:
        if v is None:
            return v
        lowered = v.strip().lower()
        if not NAMED_KEY.match(lowered):
            raise ValueError("key must be a named control (e.g. 'return', 'cmd+s') or 'redacted'")
        parts = lowered.split("+")
        # A lone printable character is typed text, not a named control.
        if len(parts) == 1 and len(parts[0]) == 1:
            raise ValueError("bare character keys look like typed text; send 'redacted'")
        if len(parts) > 1 and not all(p in _MODIFIERS for p in parts[:-1]):
            raise ValueError("key chords must be modifiers followed by one key")
        return lowered

    @field_validator("accessibility")
    @classmethod
    def _bounded(cls, v):
        if isinstance(v, dict):
            if len(v) > 32:
                raise ValueError("accessibility has too many fields")
            for k, val in v.items():
                if len(k) > 64 or (isinstance(val, str) and len(val) > 500):
                    raise ValueError("accessibility field too long")
        elif isinstance(v, str) and len(v) > 1000:
            raise ValueError("accessibility too long")
        return v


class Frame(Strict):
    id: UUID
    timestamp_ms: int = Field(ge=0)
    filename: str
    width: int = Field(ge=1, le=16384)
    height: int = Field(ge=1, le=16384)
    sha256: str

    @field_validator("filename")
    @classmethod
    def _safe(cls, v: str) -> str:
        if not SAFE_FILENAME.match(v) or ".." in v:
            raise ValueError("filename must be a safe relative basename")
        ext = v[v.rfind(".") :].lower() if "." in v else ""
        if ext not in ALLOWED_FRAME_EXT:
            raise ValueError("frame must be .png, .jpg or .jpeg")
        return v

    @field_validator("sha256")
    @classmethod
    def _hex(cls, v: str) -> str:
        v = v.lower()
        if not SHA256_HEX.match(v):
            raise ValueError("sha256 must be 64 lowercase hex characters")
        return v


class Network(Strict):
    id: UUID
    timestamp_ms: int = Field(ge=0)
    method: str = Field(min_length=1, max_length=16, pattern=r"^[A-Za-z]+$")
    url: str = Field(min_length=1, max_length=4096)
    status: int | None = Field(default=None, ge=0, le=999)
    request_headers: dict[str, str] | None = None
    response_headers: dict[str, str] | None = None
    request_body: str | None = Field(default=None, max_length=4096)
    response_body: str | None = Field(default=None, max_length=4096)

    @field_validator("request_headers", "response_headers")
    @classmethod
    def _headers(cls, v):
        if v is not None and len(v) > 100:
            raise ValueError("too many headers")
        return v

    @field_validator("url")
    @classmethod
    def _scheme(cls, v: str) -> str:
        if not re.match(r"^(https?|wss?)://", v, re.IGNORECASE):
            raise ValueError("url must be http(s) or ws(s)")
        return v


class Redaction(Strict):
    reviewed: Literal[True]
    notes: str | None = Field(default=None, max_length=1000)


class NetworkCapture(Strict):
    """Optional additive field: whether network capture actually ran."""

    status: Literal["captured", "not_captured"]
    tool: str | None = Field(default=None, max_length=80)


class Manifest(Strict):
    schema_version: Literal[1]
    id: UUID
    project_id: str = Field(min_length=1, max_length=64)
    app: AppInfo
    task: str = Field(min_length=1, max_length=2000)
    started_at: datetime
    duration_ms: int = Field(ge=0, le=6 * 3600 * 1000)
    interactions: list[Interaction]
    frames: list[Frame]
    network: list[Network]
    redaction: Redaction
    network_capture: NetworkCapture | None = None

    @field_validator("started_at")
    @classmethod
    def _utc(cls, v: datetime) -> datetime:
        if v.tzinfo is None or v.utcoffset() is None or v.utcoffset().total_seconds() != 0:
            raise ValueError("started_at must be an ISO 8601 UTC timestamp")
        return v

    @model_validator(mode="after")
    def _references(self) -> "Manifest":
        ids: set[UUID] = set()
        for group in (self.frames, self.interactions, self.network):
            for item in group:
                if item.id in ids:
                    raise ValueError(f"duplicate evidence id {item.id}")
                ids.add(item.id)
                if item.timestamp_ms > self.duration_ms + 1000:
                    raise ValueError(f"evidence {item.id} timestamp exceeds duration_ms")
        filenames = [f.filename.lower() for f in self.frames]
        if len(set(filenames)) != len(filenames):
            raise ValueError("duplicate frame filenames")
        frame_ids = {f.id for f in self.frames}
        for i in self.interactions:
            for ref in (i.before_frame_id, i.after_frame_id):
                if ref is not None and ref not in frame_ids:
                    raise ValueError(f"interaction {i.id} references unknown frame {ref}")
        if self.network_capture and self.network_capture.status == "not_captured" and self.network:
            raise ValueError("network entries present but network_capture.status is not_captured")
        return self

    @property
    def capture_status(self) -> str:
        if self.network_capture is not None:
            return self.network_capture.status
        return "captured" if self.network else "not_captured"
