"""Run the API: `uv run python -m retrace` (binds RETRACE_HOST, default 127.0.0.1)."""

from __future__ import annotations

import os

import uvicorn

from .app import create_app
from .config import Settings


def main() -> None:
    settings = Settings.from_env()
    port = int(os.environ.get("RETRACE_PORT", "8000"))
    # proxy_headers off: forwarded headers are never trusted for client identity.
    uvicorn.run(create_app(settings), host=settings.host, port=port, proxy_headers=False, server_header=False)


if __name__ == "__main__":
    main()
