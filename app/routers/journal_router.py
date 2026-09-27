import logging
from typing import AsyncGenerator

from fastapi import APIRouter, Depends, HTTPException, Request
from models.entry import Entry, EntryCreate, EntryUpdate
from repositories.postgres_repository import PostgresDB
from services.entry_service import EntryService

router = APIRouter()
logger = logging.getLogger("journal")

# TODO: Add authentication middleware
# TODO: Add request validation middleware
# TODO: Add rate limiting middleware
# TODO: Add API versioning
# TODO: Add response caching

async def get_entry_service(request: Request) -> AsyncGenerator[EntryService, None]:
    # Uses the pool created once at startup (main.py) instead of opening a new
    # pool, and with it new database connections, for every request.
    yield EntryService(PostgresDB(request.app.state.db_pool))

@router.post("/entries")
async def create_entry(entry_data: EntryCreate, entry_service: EntryService = Depends(get_entry_service)):
    """Create a new journal entry."""
    try:
        # Create the full entry with auto-generated fields
        entry = Entry(
            work=entry_data.work,
            struggle=entry_data.struggle,
            intention=entry_data.intention
        )

        # Store the entry in the database
        created_entry = await entry_service.create_entry(entry.model_dump())

        # Return success response (FastAPI handles datetime serialization automatically)
        return {
            "detail": "Entry created successfully",
            "entry": created_entry
        }
    except Exception as e:
        # Details go to the log only. Returning str(e) would expose internals
        # (e.g. database errors) to the client (CWE-209).
        logger.exception("Error creating entry")
        raise HTTPException(status_code=400, detail="Error creating entry") from e

# Implements GET /entries endpoint to list all journal entries
# Example response: [{"id": "123", "work": "...", "struggle": "...", "intention": "..."}]
@router.get("/entries")
async def get_all_entries(entry_service: EntryService = Depends(get_entry_service)):
    """Get all journal entries."""
    result = await entry_service.get_all_entries()
    return {"entries": result, "count": len(result)}


@router.get("/entries/{entry_id}")
async def get_entry(request: Request, entry_id: str, entry_service: EntryService = Depends(get_entry_service)):
    """return a single journal entry by ID"""
    result = await entry_service.get_entry(entry_id)
    if not result:
        raise HTTPException(status_code=404, detail="Entry not found")
    return result


@router.patch("/entries/{entry_id}")
async def update_entry(
    entry_id: str, entry_update: EntryUpdate, entry_service: EntryService = Depends(get_entry_service)
):
    """Update a journal entry. Only the fields that are sent are changed."""
    # exclude_unset: fields the client did not send; exclude_none: explicit nulls
    changes = entry_update.model_dump(exclude_unset=True, exclude_none=True)
    if not changes:
        raise HTTPException(status_code=400, detail="No fields to update")
    result = await entry_service.update_entry(entry_id, changes)
    if not result:
        raise HTTPException(status_code=404, detail="Entry not found")
    return result


@router.delete("/entries/{entry_id}")
async def delete_entry(entry_id: str, entry_service: EntryService = Depends(get_entry_service)):
    """Delete a single journal entry"""
    existing = await entry_service.get_entry(entry_id)
    if not existing:
        raise HTTPException(status_code=404, detail="Entry not found")
    await entry_service.delete_entry(entry_id)
    return {"detail": "Entry deleted"}


@router.delete("/entries")
async def delete_all_entries(entry_service: EntryService = Depends(get_entry_service)):
    """Delete all journal entries"""
    await entry_service.delete_all_entries()
    return {"detail": "All entries deleted"}
