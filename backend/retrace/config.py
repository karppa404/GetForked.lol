"""Runtime configuration, read from environment variables only.

Secrets (API keys, SpacetimeDB tokens) are read here and never logged or
returned. `Settings.public_summary()` is the only view used by /health.
"""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(RuntimeError):
    pass


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    return value.strip()


def _int(name: str, default: int) -> int:
    raw = _env(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer") from exc


def _float(name: str, default: float | None) -> float | None:
    raw = _env(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be a number") from exc


def _bool(name: str, default: bool = False) -> bool:
    raw = _env(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


def is_loopback_host(host: str | None) -> bool:
    if not host:
        return False
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


@dataclass
class LLMSettings:
    base_url: str | None = None
    api_key: str | None = field(default=None, repr=False)
    provider: str = "openai_compatible"  # or "offline_heuristic" for credit-free local dev
    model_default: str | None = None
    model_workflow: str | None = None
    model_network: str | None = None
    model_reconcile: str | None = None
    model_publish: str | None = None
    vision_enabled: bool = False
    timeout_s: float = 60.0
    max_retries: int = 2
    max_output_tokens: int = 2048
    max_prompt_chars: int = 60_000
    max_frames_per_job: int = 4
    max_frame_bytes: int = 1_500_000
    max_calls_per_job: int = 8
    max_tokens_per_job: int = 150_000
    max_concurrent_calls: int = 2
    max_concurrent_jobs: int = 1
    max_job_seconds: float = 600.0
    budget_total_tokens: int = 3_000_000
    budget_usd: float = 45.0
    price_input_per_mtok: float | None = None
    price_output_per_mtok: float | None = None
    temperature: float = 0.1

    def model_for(self, stage: str) -> str | None:
        specific = {
            "workflow": self.model_workflow,
            "network": self.model_network,
            "reconcile": self.model_reconcile,
            "publish": self.model_publish,
        }.get(stage)
        return specific or self.model_default

    @property
    def keyless_allowed(self) -> bool:
        """A key may be omitted only for a loopback endpoint (e.g. an SSH/Brev port
        forward to a self-hosted NIM/vLLM server)."""
        from urllib.parse import urlsplit

        return bool(self.base_url) and is_loopback_host(urlsplit(self.base_url).hostname)

    @property
    def configured(self) -> bool:
        if self.provider == "offline_heuristic":
            return True
        return bool(self.base_url and (self.api_key or self.keyless_allowed) and all(
            self.model_for(s) for s in ("workflow", "network", "reconcile", "publish")
        ))


@dataclass
class Settings:
    environment: str = "development"  # development | test | production
    host: str = "127.0.0.1"
    data_dir: Path = Path("./data")
    cors_origins: list[str] = field(default_factory=lambda: ["http://localhost:3000", "http://127.0.0.1:3000"])
    public_base_url: str | None = None

    dev_auth_enabled: bool = False
    google_client_id: str | None = None
    google_allowed_domains: list[str] = field(default_factory=list)
    access_token_ttl_s: int = 12 * 3600

    pairing_ttl_s: int = 600
    claim_ttl_s: int = 600
    poll_min_interval_s: float = 1.0
    poll_max_count: int = 900

    state_backend: str = "local"  # local | spacetimedb
    spacetime_uri: str | None = None
    spacetime_database: str | None = None
    spacetime_token: str | None = field(default=None, repr=False)
    spacetime_timeout_s: float = 10.0
    allow_local_state_in_production: bool = False

    max_manifest_bytes: int = 2 * 1024 * 1024
    max_frames: int = 300
    max_interactions: int = 5000
    max_network: int = 2000
    max_file_bytes: int = 10 * 1024 * 1024
    max_upload_bytes: int = 250 * 1024 * 1024

    analyze_dedupe_window_s: float = 120.0
    inline_jobs: bool = False  # tests run analysis synchronously
    llm: LLMSettings = field(default_factory=LLMSettings)

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    @classmethod
    def from_env(cls) -> "Settings":
        origins = _env("RETRACE_CORS_ORIGINS")
        domains = _env("RETRACE_GOOGLE_ALLOWED_DOMAINS")
        token = _env("RETRACE_SPACETIME_TOKEN")
        token_file = _env("RETRACE_SPACETIME_TOKEN_FILE")
        if token is None and token_file:
            token = Path(token_file).read_text().strip() or None
        model_api_key = _env("RETRACE_LLM_API_KEY")
        if model_api_key is None and (key_file := _env("RETRACE_LLM_API_KEY_FILE")):
            model_api_key = Path(key_file).read_text().strip() or None
        llm = LLMSettings(
            base_url=_env("RETRACE_LLM_BASE_URL"),
            api_key=model_api_key,
            provider=_env("RETRACE_LLM_PROVIDER", "openai_compatible") or "openai_compatible",
            model_default=_env("RETRACE_LLM_MODEL"),
            model_workflow=_env("RETRACE_LLM_MODEL_WORKFLOW"),
            model_network=_env("RETRACE_LLM_MODEL_NETWORK"),
            model_reconcile=_env("RETRACE_LLM_MODEL_RECONCILE"),
            model_publish=_env("RETRACE_LLM_MODEL_PUBLISH"),
            vision_enabled=_bool("RETRACE_LLM_VISION", False),
            timeout_s=_float("RETRACE_LLM_TIMEOUT_S", 60.0) or 60.0,
            max_retries=_int("RETRACE_LLM_MAX_RETRIES", 2),
            max_output_tokens=_int("RETRACE_LLM_MAX_OUTPUT_TOKENS", 2048),
            max_prompt_chars=_int("RETRACE_LLM_MAX_PROMPT_CHARS", 60_000),
            max_frames_per_job=_int("RETRACE_LLM_MAX_FRAMES", 4),
            max_calls_per_job=_int("RETRACE_LLM_MAX_CALLS_PER_JOB", 8),
            max_tokens_per_job=_int("RETRACE_LLM_MAX_TOKENS_PER_JOB", 150_000),
            max_concurrent_calls=_int("RETRACE_LLM_MAX_CONCURRENCY", 2),
            max_concurrent_jobs=_int("RETRACE_MAX_CONCURRENT_JOBS", 1),
            max_job_seconds=_float("RETRACE_LLM_MAX_JOB_SECONDS", 600.0) or 600.0,
            budget_total_tokens=_int("RETRACE_BUDGET_TOTAL_TOKENS", 3_000_000),
            budget_usd=_float("RETRACE_BUDGET_USD", 45.0) or 45.0,
            price_input_per_mtok=_float("RETRACE_PRICE_INPUT_PER_MTOK", None),
            price_output_per_mtok=_float("RETRACE_PRICE_OUTPUT_PER_MTOK", None),
        )
        settings = cls(
            environment=_env("RETRACE_ENV", "development") or "development",
            host=_env("RETRACE_HOST", "127.0.0.1") or "127.0.0.1",
            data_dir=Path(_env("RETRACE_DATA_DIR", "./data") or "./data"),
            cors_origins=[o.strip() for o in origins.split(",")] if origins else cls().cors_origins,
            public_base_url=_env("RETRACE_PUBLIC_BASE_URL"),
            dev_auth_enabled=_bool("RETRACE_DEV_AUTH", False),
            google_client_id=_env("RETRACE_GOOGLE_CLIENT_ID"),
            google_allowed_domains=[d.strip().lower() for d in domains.split(",")] if domains else [],
            state_backend=_env("RETRACE_STATE_BACKEND", "local") or "local",
            spacetime_uri=_env("RETRACE_SPACETIME_URI"),
            spacetime_database=_env("RETRACE_SPACETIME_DATABASE"),
            spacetime_token=token,
            allow_local_state_in_production=_bool("RETRACE_ALLOW_LOCAL_STATE_IN_PRODUCTION", False),
            llm=llm,
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if self.environment not in {"development", "test", "production"}:
            raise ConfigError("RETRACE_ENV must be development, test or production")
        if self.dev_auth_enabled and self.is_production:
            raise ConfigError("RETRACE_DEV_AUTH cannot be enabled when RETRACE_ENV=production")
        if self.dev_auth_enabled and not is_loopback_host(self.host):
            raise ConfigError("RETRACE_DEV_AUTH requires binding to a loopback RETRACE_HOST")
        if self.state_backend not in {"local", "spacetimedb"}:
            raise ConfigError("RETRACE_STATE_BACKEND must be local or spacetimedb")
        if self.state_backend == "local" and self.is_production and not self.allow_local_state_in_production:
            raise ConfigError("local development state is not allowed in production; configure SpacetimeDB")
        if self.llm.provider not in {"openai_compatible", "offline_heuristic"}:
            raise ConfigError("RETRACE_LLM_PROVIDER must be openai_compatible or offline_heuristic")
        if self.llm.provider == "offline_heuristic" and self.is_production:
            raise ConfigError("offline heuristic analysis is a development tool; not allowed in production")
        if self.llm.base_url and not self.llm.keyless_allowed and not self.llm.base_url.startswith("https://"):
            raise ConfigError("RETRACE_LLM_BASE_URL must use https unless it is a loopback port forward")
        if "*" in self.cors_origins and self.is_production:
            raise ConfigError("wildcard CORS is not allowed in production")
