"""Test setup: the API runs in-process (FastAPI TestClient) against a real
PostgreSQL database, locally in Docker, in the pipeline as a service container.

DATABASE_URL must point to an empty test database. It is never the Azure one:
that is only reachable from inside the cluster.
"""
import asyncio
import os
import sys
from pathlib import Path

import asyncpg
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
# The app uses imports relative to app/ (e.g. "from routers ..."), as in the image.
sys.path.insert(0, str(ROOT / "app"))
sys.path.insert(0, str(ROOT / "scripts"))
os.environ.setdefault("DATABASE_URL", "postgresql://postgres:test@localhost:5432/learning_journal")

from main import app  # noqa: E402  (needs the path and DATABASE_URL above)


def run_sql(sql: str) -> None:
    async def run():
        conn = await asyncpg.connect(os.environ["DATABASE_URL"])
        try:
            await conn.execute(sql)
        finally:
            await conn.close()
    asyncio.run(run())


@pytest.fixture(scope="session", autouse=True)
def schema():
    """Same SQL as the schema job in the cluster."""
    run_sql((ROOT / "db" / "schema.sql").read_text())


@pytest.fixture
def client():
    """An empty table for every test, and the app with its startup (lifespan)."""
    run_sql("TRUNCATE entries")
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def entry(client):
    """One stored entry to work with."""
    response = client.post("/entries", json={"work": "w", "struggle": "s", "intention": "i"})
    assert response.status_code == 200
    return response.json()["entry"]
