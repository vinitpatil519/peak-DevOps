"""Redis client wrapper with graceful degradation: cache failures never fail a request."""

import json
import logging
from typing import Any

import redis.asyncio as redis

from app.config import get_settings
from app.metrics import CACHE_EVENTS

log = logging.getLogger(__name__)
_client: redis.Redis | None = None


def get_redis() -> redis.Redis:
    global _client
    if _client is None:
        s = get_settings()
        _client = redis.Redis(
            host=s.redis_host,
            port=s.redis_port,
            password=s.redis_password,
            db=s.redis_db,
            decode_responses=True,
            socket_timeout=0.5,
            socket_connect_timeout=0.5,
        )
    return _client


def set_redis(client: redis.Redis) -> None:
    """Test hook for injecting a fake client."""
    global _client
    _client = client


async def cache_get(key: str) -> Any | None:
    try:
        raw = await get_redis().get(key)
    except redis.RedisError as exc:
        log.warning("cache get failed", extra={"key": key, "error": str(exc)})
        CACHE_EVENTS.labels(result="error").inc()
        return None
    CACHE_EVENTS.labels(result="hit" if raw is not None else "miss").inc()
    return json.loads(raw) if raw is not None else None


async def cache_set(key: str, value: Any, ttl: int | None = None) -> None:
    try:
        await get_redis().set(
            key, json.dumps(value, default=str), ex=ttl or get_settings().cache_ttl_seconds
        )
    except redis.RedisError as exc:
        log.warning("cache set failed", extra={"key": key, "error": str(exc)})
        CACHE_EVENTS.labels(result="error").inc()


async def cache_delete(*keys: str) -> None:
    try:
        await get_redis().delete(*keys)
    except redis.RedisError as exc:
        log.warning("cache delete failed", extra={"keys": list(keys), "error": str(exc)})
