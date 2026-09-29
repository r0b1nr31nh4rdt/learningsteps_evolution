"""Prometheus metrics of the API.

Served on their own port (METRICS_PORT, default 9000), not on the API port:
the ingress only forwards the API port, so /metrics is not reachable from the
internet, only from inside the cluster (and there only from Prometheus, see
the NetworkPolicy in k8s-manifests/platform.yaml).
"""
import asyncio
import logging
import os
import time

import asyncpg
from fastapi import Request
from prometheus_client import Counter, Gauge, Histogram, start_http_server

logger = logging.getLogger(__name__)

METRICS_PORT = int(os.getenv("METRICS_PORT", "9000"))  # 0 = do not start (tests)
DB_CHECK_INTERVAL_SECONDS = 15

REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests handled by the API",
    ["method", "path", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "Time to answer an HTTP request",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
DB_UP = Gauge("db_up", "1 if the last database check (SELECT 1) succeeded, else 0")
DB_CHECK_SECONDS = Gauge("db_check_duration_seconds", "Duration of the last database check")
DB_POOL = Gauge("db_pool_connections", "Connections of the database pool", ["state"])


def start_metrics_server() -> None:
    if METRICS_PORT:
        start_http_server(METRICS_PORT)
        logger.info("Metrics served on port %d", METRICS_PORT)


async def record_request(request: Request, call_next):
    """Middleware: count every request and measure its duration.

    The path label is the route template ("/entries/{entry_id}"), not the real
    URL; otherwise every entry ID would create its own time series.
    """
    start = time.perf_counter()
    status = 500  # if the handler raises, the client gets a 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        path = route.path if route else "unmatched"
        REQUESTS.labels(request.method, path, str(status)).inc()
        LATENCY.labels(request.method, path).observe(time.perf_counter() - start)


async def watch_database(pool: asyncpg.Pool) -> None:
    """Background task: check the database regularly, independent of scrapes."""
    while True:
        start = time.perf_counter()
        try:
            async with pool.acquire(timeout=5) as conn:
                await conn.fetchval("SELECT 1")
            DB_UP.set(1)
        except Exception:
            logger.warning("Database check failed", exc_info=True)
            DB_UP.set(0)
        DB_CHECK_SECONDS.set(time.perf_counter() - start)
        DB_POOL.labels("open").set(pool.get_size())
        DB_POOL.labels("idle").set(pool.get_idle_size())
        await asyncio.sleep(DB_CHECK_INTERVAL_SECONDS)
