"""Google Identity Services ID token verification.

Uses google-auth to verify signature (Google's published certs), audience
(RETRACE_GOOGLE_CLIENT_ID), issuer, and expiry. Requires email_verified.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

GOOGLE_ISSUERS = {"accounts.google.com", "https://accounts.google.com"}


class GoogleAuthError(Exception):
    pass


@dataclass
class GoogleIdentity:
    subject: str
    email: str
    name: str | None
    hosted_domain: str | None


def _default_verifier(credential: str, client_id: str) -> dict:
    from google.auth.transport import requests as google_requests
    from google.oauth2 import id_token

    return id_token.verify_oauth2_token(credential, google_requests.Request(), client_id, clock_skew_in_seconds=10)


class GoogleVerifier:
    def __init__(self, client_id: str, allowed_domains: list[str], verify: Callable[[str, str], dict] | None = None):
        self.client_id = client_id
        self.allowed_domains = allowed_domains
        self._verify = verify or _default_verifier

    def verify(self, credential: str) -> GoogleIdentity:
        try:
            claims = self._verify(credential, self.client_id)
        except Exception as exc:  # google-auth raises ValueError/GoogleAuthError variants
            raise GoogleAuthError("invalid Google credential") from exc
        if claims.get("iss") not in GOOGLE_ISSUERS:
            raise GoogleAuthError("invalid issuer")
        if claims.get("aud") != self.client_id:
            raise GoogleAuthError("invalid audience")
        if not claims.get("email") or claims.get("email_verified") not in (True, "true"):
            raise GoogleAuthError("email not verified")
        email = str(claims["email"]).lower()
        domain = claims.get("hd")
        if self.allowed_domains:
            email_domain = email.rsplit("@", 1)[-1]
            if email_domain not in self.allowed_domains and (domain or "").lower() not in self.allowed_domains:
                raise GoogleAuthError("account domain not allowed")
        return GoogleIdentity(str(claims["sub"]), email, claims.get("name"), domain)
