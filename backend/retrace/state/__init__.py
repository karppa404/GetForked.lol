from __future__ import annotations

from ..config import ConfigError, Settings
from .base import SharedState, StateUnavailable
from .local import LocalDevState
from .spacetime import SpacetimeState


def build_state(settings: Settings) -> SharedState:
    if settings.state_backend == "spacetimedb":
        missing = [
            name
            for name, value in (
                ("RETRACE_SPACETIME_URI", settings.spacetime_uri),
                ("RETRACE_SPACETIME_DATABASE", settings.spacetime_database),
                ("RETRACE_SPACETIME_TOKEN or RETRACE_SPACETIME_TOKEN_FILE", settings.spacetime_token),
            )
            if not value
        ]
        if missing:
            raise ConfigError("spacetimedb state backend selected but missing: " + ", ".join(missing))
        return SpacetimeState(
            settings.spacetime_uri, settings.spacetime_database, settings.spacetime_token, settings.spacetime_timeout_s
        )
    return LocalDevState(settings.data_dir / "local-dev-state.sqlite3")


__all__ = ["SharedState", "StateUnavailable", "LocalDevState", "SpacetimeState", "build_state"]
