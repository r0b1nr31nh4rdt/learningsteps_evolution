"""API tests: create, read, update, delete, and input validation."""


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_root_redirects_to_docs(client):
    response = client.get("/", follow_redirects=False)
    assert response.status_code in (302, 307)
    assert response.headers["location"] == "/docs"


def test_create_and_read(client, entry):
    assert entry["id"]
    response = client.get(f"/entries/{entry['id']}")
    assert response.status_code == 200
    assert response.json()["work"] == "w"


def test_create_requires_all_fields(client):
    response = client.post("/entries", json={"work": "only this"})
    assert response.status_code == 422


def test_create_rejects_too_long_text(client):
    response = client.post("/entries", json={"work": "x" * 257, "struggle": "s", "intention": "i"})
    assert response.status_code == 422


def test_list_counts_entries(client, entry):
    client.post("/entries", json={"work": "a", "struggle": "b", "intention": "c"})
    body = client.get("/entries").json()
    assert body["count"] == 2
    assert len(body["entries"]) == 2


def test_read_unknown_returns_404(client):
    assert client.get("/entries/does-not-exist").status_code == 404


def test_patch_changes_only_sent_fields(client, entry):
    response = client.patch(f"/entries/{entry['id']}", json={"work": "new"})
    assert response.status_code == 200
    stored = client.get(f"/entries/{entry['id']}").json()
    assert (stored["work"], stored["struggle"], stored["intention"]) == ("new", "s", "i")


def test_patch_ignores_explicit_null(client, entry):
    client.patch(f"/entries/{entry['id']}", json={"work": None, "struggle": "new"})
    stored = client.get(f"/entries/{entry['id']}").json()
    assert (stored["work"], stored["struggle"]) == ("w", "new")


def test_patch_with_empty_body_returns_400(client, entry):
    assert client.patch(f"/entries/{entry['id']}", json={}).status_code == 400


def test_patch_unknown_returns_404(client):
    assert client.patch("/entries/does-not-exist", json={"work": "x"}).status_code == 404


def test_patch_cannot_overwrite_protected_fields(client, entry):
    """Mass assignment: fields outside the model (id, created_at, ...) are dropped."""
    client.patch(f"/entries/{entry['id']}", json={
        "work": "changed", "id": "hijacked", "created_at": "2000-01-01T00:00:00Z", "mood": "x",
    })
    stored = client.get(f"/entries/{entry['id']}").json()
    assert stored["id"] == entry["id"]
    assert stored["created_at"] == entry["created_at"]
    assert "mood" not in stored
    assert client.get("/entries/hijacked").status_code == 404


def test_delete(client, entry):
    assert client.delete(f"/entries/{entry['id']}").status_code == 200
    assert client.get(f"/entries/{entry['id']}").status_code == 404
