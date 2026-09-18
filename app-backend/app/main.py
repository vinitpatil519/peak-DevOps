"""CloudForge API entrypoint."""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import make_asgi_app

from app.config import get_settings
from app.db import engine, init_models
from app.logging_config import configure_logging
from app.metrics import MetricsMiddleware
from app.routers import catalog, health

settings = get_settings()
configure_logging(settings.log_level)
log = logging.getLogger("cloudforge")


@asynccontextmanager
async def lifespan(_: FastAPI):
    log.info("starting", extra={"env": settings.environment, "version": settings.version})
    await init_models()
    yield
    await engine.dispose()
    log.info("stopped")


app = FastAPI(
    title="CloudForge API",
    version=settings.version,
    lifespan=lifespan,
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
)
app.add_middleware(MetricsMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
app.include_router(health.router)
app.include_router(catalog.router)
app.mount("/metrics", make_asgi_app())
