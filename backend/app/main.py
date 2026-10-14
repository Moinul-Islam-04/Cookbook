"""App factory. Run with:  uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000"""

import logging
import re
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from sqlalchemy import create_engine, text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import sessionmaker

from app.config import DEV_USER_ID, Settings, get_settings
from app.errors import install_error_handlers
from app.extraction import make_extractor
from app.models import User
from app.routers import import_drafts, recipes

log = logging.getLogger("cookbook")
_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def ensure_dev_user(session_factory: sessionmaker) -> None:
    with session_factory() as session:
        session.execute(insert(User).values(id=DEV_USER_ID).on_conflict_do_nothing())
        session.commit()


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s:     %(name)s %(message)s")
    if settings.auth_mode != "dev":
        raise RuntimeError(
            "Only COOKBOOK_AUTH_MODE=dev is implemented. Real authentication arrives in "
            "Milestone 4; until then this server must stay local and single-user."
        )

    # Sessions run in UTC so every timestamp the API returns is UTC.
    engine = create_engine(
        settings.database_url, pool_pre_ping=True, connect_args={"options": "-c timezone=UTC"}
    )
    session_factory = sessionmaker(engine, expire_on_commit=False)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        ensure_dev_user(session_factory)
        yield
        engine.dispose()

    app = FastAPI(title="Cookbook API", version="0.1.0", lifespan=lifespan)
    app.state.engine = engine
    app.state.sessionmaker = session_factory
    app.state.settings = settings
    # Tests swap this for a FakeExtractor with canned responses.
    app.state.extractor = make_extractor(settings.extraction_provider)

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        incoming = request.headers.get("x-request-id", "")
        request_id = incoming if _REQUEST_ID.match(incoming) else uuid.uuid4().hex
        request.state.request_id = request_id
        start = time.perf_counter()
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        # Method, path, status and timing only: never request or response bodies.
        log.info(
            "%s %s -> %s %.1fms rid=%s",
            request.method,
            request.url.path,
            response.status_code,
            (time.perf_counter() - start) * 1000,
            request_id,
        )
        return response

    install_error_handlers(app)
    app.include_router(recipes.router)
    app.include_router(import_drafts.router)

    @app.get("/healthz", tags=["health"])
    def healthz() -> dict[str, str]:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return {"status": "ok"}

    return app
