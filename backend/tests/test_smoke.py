from fastapi.testclient import TestClient

from app.main import API_KEY, LOCATIONS_FILE, app, read_locations


def test_included_workbook_has_expected_coverage():
    rows = read_locations(LOCATIONS_FILE)
    assert len(rows) == 228
    assert len({r["pin_code"] for r in rows if r["pin_code"]}) == 102
    assert all(r["valid_pin"] for r in rows)


def test_api_key_protects_control_api():
    with TestClient(app) as client:
        assert client.get("/api/status").status_code == 401
        response = client.get("/api/status", headers={"X-API-Key": API_KEY})
        assert response.status_code == 200
        assert response.json()["locations_total"] == 228


def test_demo_test_event_is_marked_as_simulated():
    with TestClient(app) as client:
        response = client.post("/api/test-event", headers={"X-API-Key": API_KEY}, json={})
        assert response.status_code == 200
        event = response.json()["event"]
        assert event["is_demo"] is True
        assert event["available"] is True
