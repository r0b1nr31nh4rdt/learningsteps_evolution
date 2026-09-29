"""Prometheus metrics: requests are counted per route template."""
from prometheus_client import REGISTRY, generate_latest


def count(method, path, status):
    value = REGISTRY.get_sample_value(
        "http_requests_total", {"method": method, "path": path, "status": status}
    )
    return value or 0


def test_requests_are_counted_per_route_template(client, entry):
    before = count("GET", "/entries/{entry_id}", "200")
    client.get(f"/entries/{entry['id']}")
    client.get(f"/entries/{entry['id']}")
    assert count("GET", "/entries/{entry_id}", "200") == before + 2


def test_real_ids_do_not_become_labels(client, entry):
    client.get(f"/entries/{entry['id']}")
    assert entry["id"].encode() not in generate_latest(REGISTRY)


def test_status_codes_are_recorded(client):
    before = count("GET", "/entries/{entry_id}", "404")
    client.get("/entries/does-not-exist")
    assert count("GET", "/entries/{entry_id}", "404") == before + 1


def test_latency_is_measured(client):
    before = REGISTRY.get_sample_value(
        "http_request_duration_seconds_count", {"method": "GET", "path": "/health"}
    ) or 0
    client.get("/health")
    after = REGISTRY.get_sample_value(
        "http_request_duration_seconds_count", {"method": "GET", "path": "/health"}
    )
    assert after == before + 1
