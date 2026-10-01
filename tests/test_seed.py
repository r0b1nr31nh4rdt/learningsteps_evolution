"""The seed script, run against the in-process API instead of a real URL."""
import pytest
import seed_demo_data

BASE_URL = "http://test"


@pytest.fixture
def seed(client, monkeypatch):
    def request_via_test_client(method, url, body=None):
        response = client.request(method, url.removeprefix(BASE_URL), json=body)
        response.raise_for_status()
        return response.json()

    monkeypatch.setattr(seed_demo_data, "request", request_via_test_client)
    monkeypatch.setattr("sys.argv", ["seed_demo_data.py", BASE_URL])
    return seed_demo_data.main


def test_seed_fills_empty_database(client, seed):
    seed()
    entries = client.get("/entries").json()["entries"]
    assert len(entries) == seed_demo_data.NUMBER_OF_ENTRIES
    assert len({e["work"] for e in entries}) == len(entries)   # no duplicates


def test_seed_leaves_existing_data_alone(client, entry, seed):
    seed()
    assert client.get("/entries").json()["count"] == 1
