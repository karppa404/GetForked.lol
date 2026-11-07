"""Pydantic models for the HTTP v1 contract (docs/INTEGRATION.md)."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

SAFE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
ALLOWED_FRAME_EXT = {".png", ".jpg", ".jpeg"}
# Mirrors macos/Sources/RetraceCore/KeyNaming.swift (isSafeKeyValue).
NAMED_KEYS = {
    "return", "enter", "tab", "delete", "forward_delete", "escape", "left", "right", "down", "up",
    "home", "end", "page_up", "page_down", "help",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
}
SHORTCUT_KEYS = set("abcdefghijklmnopqrstuvwxyz0123456789") | {
    "minus", "equal", "left_bracket", "right_bracket", "semicolon", "quote", "comma", "period",
    "slash", "backslash", "grave", "space",
}
MODIFIERS = {"ctrl", "opt", "shift", "cmd"}
REDACTED_KEY = "redacted"
INTERACTION_KINDS = (
    "click", "double_click", "right_click", "other_click", "scroll", "key", "text_input", "focus_lost", "focus_regained",
)
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


class LocalConnect(Strict):
    device_name: str = Field(min_length=1, max_length=80)

    @field_validator("device_name")
    @classmethod
    def _clean(cls, v: str) -> str:
        return PairingClaim._clean(v)


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


class BoardPut(Strict):
    """FigJam board link for a session; https figma.com URLs only, or null to clear."""

    board_url: str | None = Field(default=None, max_length=500)

    @field_validator("board_url")
    @classmethod
    def _figma(cls, v: str | None) -> str | None:
        if v is None:
            return v
        from urllib.parse import urlsplit

        parts = urlsplit(v.strip())
        host = (parts.hostname or "").lower()
        if parts.scheme != "https" or not parts.path.startswith("/") or not (host == "figma.com" or host.endswith(".figma.com")) or parts.username or parts.password:
            raise ValueError("board_url must be an https figma.com URL")
        return v.strip()


class RealtimeViewer(Strict):
    identity: str = Field(pattern=r"^(0x)?[0-9a-fA-F]{64}$")


# ---------- session manifest (aligned with macos/Sources/RetraceCore/Models.swift) ----------
class AppInfo(Strict):
    name: str = Field(min_length=1, max_length=200)
    bundle_id: str = Field(min_length=1, max_length=200)
    pid: int = Field(ge=0, le=2**31)


def is_safe_key_value(value: str) -> bool:
    if value == REDACTED_KEY:
        return True
    parts = value.split("+")
    base, mods = parts[-1], parts[:-1]
    if not base or not all(m in MODIFIERS for m in mods) or len(set(mods)) != len(mods):
        return False
    if base in NAMED_KEYS:
        return True
    if base in SHORTCUT_KEYS:
        return "cmd" in mods or "ctrl" in mods
    return False


class Accessibility(Strict):
    """Structural description of a UI element; values are never captured."""

    role: str | None = Field(default=None, max_length=256)
    subrole: str | None = Field(default=None, max_length=256)
    title: str | None = Field(default=None, max_length=256)
    label: str | None = Field(default=None, max_length=256)
    identifier: str | None = Field(default=None, max_length=256)
    window_title: str | None = Field(default=None, max_length=256)
    secure: bool | None = None

    @model_validator(mode="after")
    def _secure(self) -> "Accessibility":
        is_secure = self.secure is True or "AXSecureTextField" in (self.role, self.subrole)
        if is_secure and (self.title is not None or self.label is not None or self.identifier is not None):
            raise ValueError("secure fields must not carry title, label or identifier")
        return self

    def display(self) -> str | None:
        for v in (self.title, self.label, self.identifier, self.role):
            if v and v.strip():
                return v.strip()
        return None


class Interaction(Strict):
    id: UUID
    timestamp_ms: int = Field(ge=0)
    kind: Literal[INTERACTION_KINDS]  # type: ignore[valid-type]
    x: float | None = None
    y: float | None = None
    key: str | None = Field(default=None, max_length=60)
    scroll_dx: float | None = None
    scroll_dy: float | None = None
    accessibility: Accessibility | None = None
    before_frame_id: UUID | None = None
    after_frame_id: UUID | None = None
    delayed_frame_id: UUID | None = None

    @field_validator("key")
    @classmethod
    def _named_key(cls, v: str | None) -> str | None:
        if v is not None and not is_safe_key_value(v):
            raise ValueError("key must be a safe named key or shortcut (e.g. 'return', 'cmd+s') or 'redacted'")
        return v

    @model_validator(mode="after")
    def _text_input(self) -> "Interaction":
        if self.kind == "text_input" and self.key != REDACTED_KEY:
            raise ValueError("text_input interactions must have key 'redacted'")
        return self

    def frame_refs(self) -> list[tuple[str, UUID]]:
        return [
            (name, ref)
            for name, ref in (
                ("before_frame_id", self.before_frame_id),
                ("after_frame_id", self.after_frame_id),
                ("delayed_frame_id", self.delayed_frame_id),
            )
            if ref is not None
        ]


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
    omitted_frames: int | None = Field(default=None, ge=0)
    omitted_interactions: int | None = Field(default=None, ge=0)
    window_titles_removed: bool | None = None


class Manifest(Strict):
    schema_version: Literal[1]
    id: UUID
    project_id: str = Field(min_length=1, max_length=64)
    app: AppInfo
    task: str = Field(default="", max_length=2000)  # legacy; recorders no longer ask for intent
    started_at: datetime
    duration_ms: int = Field(ge=0, le=6 * 3600 * 1000)
    interactions: list[Interaction]
    frames: list[Frame]
    network: list[Network]
    network_status: Literal["observed", "none_observed", "not_captured"]
    redaction: Redaction

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
            for name, ref in i.frame_refs():
                if ref not in frame_ids:
                    raise ValueError(f"interaction {i.id} {name} references unknown frame {ref}")
        if self.network_status in ("not_captured", "none_observed") and self.network:
            raise ValueError(f"network must be empty when network_status is {self.network_status}")
        if self.network_status == "observed" and not self.network:
            raise ValueError("network_status observed requires network entries")
        return self

    @property
    def capture_status(self) -> str:
        """captured when a network capture actually ran (observed or none_observed)."""
        return "not_captured" if self.network_status == "not_captured" else "captured"
