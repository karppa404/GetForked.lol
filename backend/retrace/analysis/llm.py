"""Bounded access to an OpenAI-compatible chat completions endpoint
(NVIDIA Nemotron via a Brev/sponsor gateway), plus an offline heuristic
provider for credit-free development and tests.

Bounds enforced per job: call cap (every HTTP attempt counts, including
retries), token cap (reservation = estimated prompt + max output tokens),
prompt size cap, frame cap. Global bounds: concurrent call semaphore and a
persistent token ledger with a total budget stop. A dollar stop is enforced
only when provider prices are configured; otherwise /health reports that
dollar enforcement is unavailable. Exact dollar enforcement needs real
provider prices and usage reporting.
"""

from __future__ import annotations

import json
import math
import threading
import time
from dataclasses import dataclass
from typing import Callable, Protocol

import httpx

from ..config import LLMSettings


class LLMError(RuntimeError):
    pass


class TransientLLMError(LLMError):
    def __init__(self, message: str, retry_after: float | None = None):
        super().__init__(message)
        self.retry_after = retry_after


class PermanentLLMError(LLMError):
    pass


class BudgetExceeded(LLMError):
    pass


@dataclass
class ChatResponse:
    content: str
    prompt_tokens: int
    completion_tokens: int
    estimated: bool


class ChatProvider(Protocol):
    name: str

    def chat(self, model: str, messages: list[dict], max_tokens: int, temperature: float) -> ChatResponse: ...


def message_chars(messages: list[dict]) -> tuple[int, int]:
    chars = 0
    images = 0
    for m in messages:
        content = m.get("content")
        if isinstance(content, str):
            chars += len(content)
        elif isinstance(content, list):
            for part in content:
                if part.get("type") == "text":
                    chars += len(part.get("text", ""))
                elif part.get("type") == "image_url":
                    images += 1
    return chars, images


def estimate_prompt_tokens(messages: list[dict]) -> int:
    chars, images = message_chars(messages)
    # Conservative: ~3 chars/token for JSON-heavy text, 1800 tokens per image.
    return math.ceil(chars / 3) + images * 1800 + 16 * len(messages)


class OpenAICompatibleProvider:
    name = "openai_compatible"

    def __init__(self, base_url: str, api_key: str | None, timeout_s: float, transport: httpx.BaseTransport | None = None):
        headers = {"Accept": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        self._client = httpx.Client(
            base_url=base_url.rstrip("/"),
            timeout=httpx.Timeout(timeout_s, connect=min(10.0, timeout_s)),
            headers=headers,
            transport=transport,
            follow_redirects=False,  # a tunnel login redirect must not be followed with the key
        )

    def chat(self, model: str, messages: list[dict], max_tokens: int, temperature: float) -> ChatResponse:
        body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature, "stream": False}
        try:
            r = self._client.post("/chat/completions", json=body)
        except httpx.TimeoutException as exc:
            raise TransientLLMError(f"timeout: {type(exc).__name__}") from None
        except httpx.HTTPError as exc:
            raise TransientLLMError(f"transport: {type(exc).__name__}") from None
        if r.status_code == 429 or r.status_code >= 500:
            retry_after = None
            try:
                retry_after = float(r.headers.get("retry-after", ""))
            except ValueError:
                pass
            raise TransientLLMError(f"HTTP {r.status_code}", retry_after)
        if r.status_code >= 300:
            hint = " (redirect: endpoint may require browser auth; use a local port forward)" if r.status_code < 400 else ""
            raise PermanentLLMError(f"HTTP {r.status_code}{hint}")
        if "json" not in r.headers.get("content-type", ""):
            raise PermanentLLMError("non-JSON response (tunnel login page?); use a local port forward")
        try:
            data = r.json()
            content = data["choices"][0]["message"]["content"] or ""
        except (ValueError, KeyError, IndexError, TypeError):
            raise PermanentLLMError("malformed completion response") from None
        usage = data.get("usage") or {}
        if "prompt_tokens" in usage and "completion_tokens" in usage:
            return ChatResponse(content, int(usage["prompt_tokens"]), int(usage["completion_tokens"]), False)
        return ChatResponse(content, estimate_prompt_tokens(messages), math.ceil(len(content) / 3), True)


class UsageLedger(Protocol):
    def record_usage(self, job_id, stage, model, attempt, outcome, prompt, completion, estimated) -> None: ...
    def usage_totals(self) -> dict: ...


class GlobalLimiter:
    """Process-wide concurrency and in-flight token reservations."""

    def __init__(self, max_concurrent: int):
        self.semaphore = threading.BoundedSemaphore(max(1, max_concurrent))
        self.lock = threading.Lock()
        self.reserved_tokens = 0


def cost_usd(settings: LLMSettings, prompt_tokens: int, completion_tokens: int) -> float | None:
    if settings.price_input_per_mtok is None or settings.price_output_per_mtok is None:
        return None
    return prompt_tokens / 1e6 * settings.price_input_per_mtok + completion_tokens / 1e6 * settings.price_output_per_mtok


def budget_summary(settings: LLMSettings, ledger: UsageLedger) -> dict:
    totals = ledger.usage_totals()
    spent = totals["prompt_tokens"] + totals["completion_tokens"]
    usd = cost_usd(settings, totals["prompt_tokens"], totals["completion_tokens"])
    return {
        "calls": totals["calls"],
        "tokens_used": spent,
        "token_budget": settings.budget_total_tokens,
        "includes_estimates": totals["includes_estimates"],
        "usd_estimate": None if usd is None else round(usd, 4),
        "usd_budget": settings.budget_usd,
        "usd_enforcement": "configured_prices" if usd is not None else "unavailable_prices_not_configured",
        "per_job": {
            "max_calls": settings.max_calls_per_job,
            "max_tokens": settings.max_tokens_per_job,
            "max_output_tokens_per_call": settings.max_output_tokens,
            "max_frames": settings.max_frames_per_job,
            "max_prompt_chars": settings.max_prompt_chars,
            "max_seconds": settings.max_job_seconds,
        },
        "max_concurrent_calls": settings.max_concurrent_calls,
    }


class BoundedLLM:
    """Per-job wrapper enforcing all caps. Not shared between jobs."""

    def __init__(
        self,
        provider: ChatProvider,
        settings: LLMSettings,
        ledger: UsageLedger,
        limiter: GlobalLimiter,
        job_id: str,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.provider = provider
        self.settings = settings
        self.ledger = ledger
        self.limiter = limiter
        self.job_id = job_id
        self.sleep = sleep
        self.calls_used = 0
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.estimated = False
        self._lock = threading.Lock()
        self._started = time.monotonic()

    def _reserve(self, tokens: int) -> None:
        s = self.settings
        with self._lock:
            if time.monotonic() - self._started > s.max_job_seconds:
                raise BudgetExceeded(f"job wall-clock cap reached ({s.max_job_seconds:.0f}s)")
            if self.calls_used >= s.max_calls_per_job:
                raise BudgetExceeded(f"job call cap reached ({s.max_calls_per_job})")
            if self.prompt_tokens + self.completion_tokens + tokens > s.max_tokens_per_job:
                raise BudgetExceeded(f"job token cap would be exceeded ({s.max_tokens_per_job})")
            self.calls_used += 1
        with self.limiter.lock:
            totals = self.ledger.usage_totals()
            spent = totals["prompt_tokens"] + totals["completion_tokens"] + self.limiter.reserved_tokens
            if spent + tokens > s.budget_total_tokens:
                raise BudgetExceeded("global token budget would be exceeded")
            usd = cost_usd(s, totals["prompt_tokens"], totals["completion_tokens"])
            if usd is not None:
                # price pending reservations at the higher of the two rates
                worst = max(s.price_input_per_mtok or 0.0, s.price_output_per_mtok or 0.0)
                usd += (self.limiter.reserved_tokens + tokens) / 1e6 * worst
            if usd is not None and usd > s.budget_usd:
                raise BudgetExceeded("configured dollar budget would be exceeded")
            self.limiter.reserved_tokens += tokens

    def _release(self, tokens: int) -> None:
        with self.limiter.lock:
            self.limiter.reserved_tokens = max(0, self.limiter.reserved_tokens - tokens)

    def call(self, stage: str, model: str, messages: list[dict]) -> ChatResponse:
        s = self.settings
        chars, images = message_chars(messages)
        if chars > s.max_prompt_chars:
            raise BudgetExceeded(f"prompt too large ({chars} > {s.max_prompt_chars} chars)")
        if images > s.max_frames_per_job:
            raise BudgetExceeded("frame cap exceeded")
        est_prompt = estimate_prompt_tokens(messages)
        reservation = est_prompt + s.max_output_tokens
        last_error: Exception | None = None
        for attempt in range(1, s.max_retries + 2):
            self._reserve(reservation)
            try:
                with self.limiter.semaphore:
                    resp = self.provider.chat(model, messages, s.max_output_tokens, s.temperature)
            except TransientLLMError as exc:
                # The provider may still bill a failed attempt: record conservatively.
                self._account(stage, model, attempt, "transient_error", est_prompt, 0, True)
                self._release(reservation)
                last_error = exc
                if attempt <= s.max_retries:
                    delay = min(10.0, exc.retry_after if exc.retry_after is not None else 0.5 * 2 ** (attempt - 1))
                    self.sleep(delay)
                    continue
                raise LLMError(f"{stage}: retries exhausted ({exc})") from None
            except PermanentLLMError:
                self._account(stage, model, attempt, "permanent_error", est_prompt, 0, True)
                self._release(reservation)
                raise
            except BaseException:
                self._release(reservation)
                raise
            self._account(stage, model, attempt, "ok", resp.prompt_tokens, resp.completion_tokens, resp.estimated)
            self._release(reservation)
            return resp
        raise LLMError(f"{stage}: failed ({last_error})")

    def _account(self, stage, model, attempt, outcome, prompt, completion, estimated) -> None:
        with self._lock:
            self.prompt_tokens += prompt
            self.completion_tokens += completion
            self.estimated = self.estimated or estimated
        self.ledger.record_usage(self.job_id, stage, model, attempt, outcome, prompt, completion, estimated)


def extract_json(text: str) -> dict:
    """Parse the first JSON object in a model reply (tolerates code fences)."""
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1] if "\n" in t else t
        t = t.rsplit("```", 1)[0]
    start = t.find("{")
    end = t.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in model output")
    value = json.loads(t[start : end + 1])
    if not isinstance(value, dict):
        raise ValueError("model output is not a JSON object")
    return value
