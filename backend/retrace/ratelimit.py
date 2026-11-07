from __future__ import annotations

import threading
import time
from collections import defaultdict, deque


class RateLimiter:
    """In-memory sliding window limiter (per process). Good enough for a
    single API instance; use a shared limiter in front of multi-instance
    deployments."""

    def __init__(self, limit: int, window_s: float, clock=time.monotonic):
        self.limit = limit
        self.window_s = window_s
        self.clock = clock
        self._hits: dict[str, deque] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = self.clock()
        with self._lock:
            q = self._hits[key]
            while q and now - q[0] > self.window_s:
                q.popleft()
            if len(q) >= self.limit:
                return False
            q.append(now)
            if len(self._hits) > 10_000:
                for k in [k for k, v in self._hits.items() if not v][:5000]:
                    del self._hits[k]
            return True
