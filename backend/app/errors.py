"""One error envelope for every failure: code, message, field_errors, retryable, request_id."""

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import IntegrityError, OperationalError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.schemas import ErrorBody, FieldError

log = logging.getLogger("cookbook")


class ApiError(Exception):
    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        field_errors: list[FieldError] | None = None,
        retryable: bool = False,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.field_errors = field_errors or []
        self.retryable = retryable
        self.details = details


def not_found(resource: str = "recipe") -> ApiError:
    # Unowned and nonexistent resources look identical, so IDs can't be probed.
    return ApiError(404, "not_found", f"The {resource} was not found.")


def _respond(request: Request, err: ApiError) -> JSONResponse:
    body = ErrorBody(
        code=err.code,
        message=err.message,
        field_errors=err.field_errors,
        retryable=err.retryable,
        request_id=getattr(request.state, "request_id", None),
        details=err.details,
    )
    return JSONResponse(status_code=err.status_code, content=body.model_dump(mode="json"))


_STATUS_CODES = {
    400: "bad_request",
    401: "unauthenticated",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    429: "rate_limited",
}


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError) -> JSONResponse:
        return _respond(request, exc)

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError) -> JSONResponse:
        field_errors = []
        for e in exc.errors():
            loc = [str(p) for p in e.get("loc", ()) if p not in ("body", "query", "path")]
            # Messages only; never echo the submitted input back.
            field_errors.append(FieldError(field=".".join(loc) or "body", message=e["msg"]))
        return _respond(
            request,
            ApiError(422, "invalid_request", "Some fields are invalid.", field_errors=field_errors),
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _STATUS_CODES.get(exc.status_code, "error")
        message = "The resource was not found." if exc.status_code == 404 else str(exc.detail)
        return _respond(request, ApiError(exc.status_code, code, message))

    @app.exception_handler(IntegrityError)
    async def _integrity(request: Request, exc: IntegrityError) -> JSONResponse:
        # A database constraint caught something the request schema did not.
        # The transaction has already been rolled back; nothing partial was saved.
        constraint = getattr(getattr(exc.orig, "diag", None), "constraint_name", None)
        log.warning("integrity error constraint=%s", constraint)
        return _respond(
            request,
            ApiError(
                422,
                "constraint_violation",
                "The recipe violates a data rule and was not saved.",
                details={"constraint": constraint} if constraint else None,
            ),
        )

    @app.exception_handler(OperationalError)
    async def _db_unavailable(request: Request, exc: OperationalError) -> JSONResponse:
        log.error("database unavailable: %s", type(exc.orig).__name__)
        return _respond(
            request,
            ApiError(503, "database_unavailable", "The database is unavailable.", retryable=True),
        )

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
        log.exception("unhandled error")
        return _respond(request, ApiError(500, "internal_error", "Something went wrong."))
