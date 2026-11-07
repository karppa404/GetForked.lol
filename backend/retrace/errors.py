from __future__ import annotations


class ApiError(Exception):
    """Error rendered as {"error": code, "message": message, "details"?: [...]}."""

    def __init__(self, status: int, code: str, message: str, details: list | None = None, headers: dict | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.headers = headers

    def body(self) -> dict:
        out = {"error": self.code, "message": self.message}
        if self.details:
            out["details"] = self.details
        return out
