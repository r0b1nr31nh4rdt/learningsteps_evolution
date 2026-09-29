import asyncio
import contextlib
import logging
import os
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.responses import RedirectResponse
from metrics import record_request, start_metrics_server, watch_database
from repositories.postgres_repository import create_pool
from routers.journal_router import router as journal_router

load_dotenv()

logging.basicConfig(
    # From the ConfigMap app-config in Kubernetes; INFO when not set.
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)

logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Runs once per process: one connection pool for all requests.
    app.state.db_pool = await create_pool()
    logger.info("Database connection pool created")
    # Prometheus metrics on their own port, database check in the background.
    start_metrics_server()
    db_watch = asyncio.create_task(watch_database(app.state.db_pool))
    yield
    db_watch.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await db_watch
    await app.state.db_pool.close()
    logger.info("Database connection pool closed")

app = FastAPI(
    title="LearningSteps API",
    description="A simple learning journal API for tracking daily work, struggles, and intentions",
    lifespan=lifespan,
)
app.include_router(journal_router)
# Count and time every request (Prometheus, see metrics.py).
app.middleware("http")(record_request)

logger.info("LearningSteps API started")

@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse(url="/docs")

# Used by the Kubernetes probes. Deliberately does not check the database:
# if the database is down, restarting the pods would not help.
@app.get("/health", include_in_schema=False)
def health():
    return {"status": "ok"}
