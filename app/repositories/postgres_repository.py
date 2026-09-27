import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List

import asyncpg
from dotenv import load_dotenv
from repositories.interface_repository import DatabaseInterface

load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise ValueError("DATABASE_URL environment variable is missing")

# At most this many connections per pod. With up to 6 pods (HPA) that is 30,
# below the ~40 connections the smallest Azure PostgreSQL size allows.
DB_POOL_MAX_SIZE = int(os.getenv("DB_POOL_MAX_SIZE", "5"))


async def create_pool() -> asyncpg.Pool:
    """Creates the one connection pool of the app (called once at startup).

    min_size=0: no connection is opened at startup, so the app also starts
    while the database is unreachable and connects on the first request.
    """
    return await asyncpg.create_pool(DATABASE_URL, min_size=0, max_size=DB_POOL_MAX_SIZE)


class PostgresDB(DatabaseInterface):
    def __init__(self, pool: asyncpg.Pool):
        # The pool is shared by all requests; it is created in main.py.
        self.pool = pool

    @staticmethod
    def datetime_serialize(obj):
        """Convert datetime objects to ISO format for JSON serialization."""
        if isinstance(obj, datetime):
                return obj.isoformat()
        raise TypeError(f"Type {type(obj)} not serializable")

    async def create_entry(self, entry_data: Dict[str, Any]) -> Dict[str, Any]:
        async with self.pool.acquire() as conn:
            query = """
            INSERT INTO entries (id, data, created_at, updated_at)
            VALUES ($1, $2, $3, $4)
            RETURNING *
            """
            entry_id = entry_data.get("id") or str(uuid.uuid4())
            data_json = json.dumps(entry_data, default=PostgresDB.datetime_serialize)

            row = await conn.fetchrow(
                query,
                entry_id,
                data_json,
                entry_data["created_at"],
                entry_data["updated_at"]
            )

            # Return a clean entry format without duplication
            if row:
                data = json.loads(row["data"])
                return {
                    "id": row["id"],
                    "work": data.get("work", ""),
                    "struggle": data.get("struggle", ""),
                    "intention": data.get("intention", ""),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"]
                }
            return {}

    async def get_all_entries(self) -> List[Dict[str, Any]]:
        async with self.pool.acquire() as conn:
            query = "SELECT * FROM entries"
            rows = await conn.fetch(query)
            entries = []
            for row in rows:
                data = json.loads(row["data"])
                entries.append({
                    "id": row["id"],
                    "work": data.get("work", ""),
                    "struggle": data.get("struggle", ""),
                    "intention": data.get("intention", ""),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"]
                })
            return entries

    async def get_entry(self, entry_id: str) -> Dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            query = "SELECT * FROM entries WHERE id = $1"
            row = await conn.fetchrow(query, entry_id)

            if row:
                data = json.loads(row["data"])
                return {
                    "id": row["id"],
                    "work": data.get("work", ""),
                    "struggle": data.get("struggle", ""),
                    "intention": data.get("intention", ""),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"]
                }
            return None

    async def update_entry(self, entry_id: str, updated_data: Dict[str, Any]) -> None:
        updated_at = datetime.now(timezone.utc)
        updated_data["id"] = entry_id
        updated_data["updated_at"] = updated_at

        data_json = json.dumps(updated_data, default=PostgresDB.datetime_serialize)

        async with self.pool.acquire() as conn:
            query = """
            UPDATE entries
            SET data = $2, updated_at = $3
            WHERE id = $1
            """
            await conn.execute(query, entry_id, data_json, updated_at)

    async def delete_entry(self, entry_id: str) -> None:
        async with self.pool.acquire() as conn:
            query = "DELETE FROM entries WHERE id = $1"
            await conn.execute(query, entry_id)

    async def delete_all_entries(self) -> None:
        async with self.pool.acquire() as conn:
            query = "DELETE FROM entries"
            await conn.execute(query)
