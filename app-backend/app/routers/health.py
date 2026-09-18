"""Kubernetes probes. Liveness = process alive. Readiness = hard dependencies reachable."""

import logging

from fastapi import APIRouter, Response, status
from sqlalchemy import text

from app.cache import get_redis
from app.config import get_settings
from app.db import engine

router = APIRouter(tags=["health"])
log = logging.getLogger(__name__)


@router.get("/healthz")
async def liveness() -> dict:
    return {"status": "ok"}


@router.get("/readyz")
async def readiness(response: Response) -> dict:
    checks = {"database": "ok", "cache": "ok"}
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001
        log.error("readiness: database down", extra={"error": str(exc)})
        checks["database"] = "down"
    try:
        await get_redis().ping()
    except Exception as exc:  # noqa: BLE001
        # Cache is a soft dependency: report degraded but stay in rotation.
        log.warning("readiness: cache down", extra={"error": str(exc)})
        checks["cache"] = "degraded"
    ready = checks["database"] == "ok"
    if not ready:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {"status": "ready" if ready else "not-ready", "checks": checks}


@router.get("/api/v1/info")
async def info() -> dict:
    s = get_settings()
    return {"service": s.app_name, "version": s.version, "environment": s.environment}
