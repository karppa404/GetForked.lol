from __future__ import annotations

import hashlib
import hmac
import secrets
from datetime import datetime, timezone

# Crockford-style alphabet without ambiguous characters (no 0/O, 1/I/L, U).
PAIRING_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
PAIRING_CODE_LEN = 8


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def new_token(prefix: str, nbytes: int = 32) -> str:
    return f"{prefix}_{secrets.token_urlsafe(nbytes)}"


def hash_secret(value: str) -> str:
    """Hash a high-entropy secret for storage. Tokens are random 256-bit
    values, so a fast hash is appropriate (no password stretching needed)."""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def secrets_equal(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def new_pairing_code() -> str:
    return "".join(secrets.choice(PAIRING_ALPHABET) for _ in range(PAIRING_CODE_LEN))


def normalize_pairing_code(code: str) -> str:
    return "".join(ch for ch in code.upper() if ch.isalnum())


def format_pairing_code(code: str) -> str:
    return f"{code[:4]}-{code[4:]}"


def mask_secret(value: str | None) -> str:
    if not value:
        return "<unset>"
    return f"<set, {len(value)} chars>"
