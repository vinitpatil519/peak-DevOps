"""Prometheus metrics: RED (rate, errors, duration) plus business counters."""

import time

from prometheus_client import Counter, Gauge, Histogram
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "route", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
IN_FLIGHT = Gauge("http_requests_in_flight", "In-flight HTTP requests")
CACHE_EVENTS = Counter("cloudforge_cache_events_total", "Cache lookups", ["result"])
ORDERS_CREATED = Counter("cloudforge_orders_created_total", "Orders created", ["product"])
ORDER_REVENUE = Counter("cloudforge_order_revenue_cents_total", "Order revenue in cents")

_SKIP = ("/metrics", "/healthz", "/readyz")


class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path.startswith(_SKIP):
            return await call_next(request)
        IN_FLIGHT.inc()
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            # Route template (e.g. /api/v1/products/{product_id}) keeps label cardinality bounded.
            route = getattr(request.scope.get("route"), "path", "unmatched")
            LATENCY.labels(request.method, route).observe(time.perf_counter() - start)
            REQUESTS.labels(request.method, route, str(status)).inc()
            IN_FLIGHT.dec()
