from __future__ import annotations

import base64
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select

from ride_relay_server.eta import cleanup_eta
from ride_relay_server.models import EtaProfile


def headers(index: int) -> dict[str, str]:
    token = base64.urlsafe_b64encode(index.to_bytes(32, "big")).decode().rstrip("=")
    return {"authorization": f"Eta eta1_{token}"}


def profile(ratio: float = 0.8) -> dict:
    return {"schemaVersion": 1, "consentVersion": "2026-09-v1", "bands": {"mixed": ratio}}


def test_minimum_independent_profiles_replacement_and_revocation(client: TestClient):
    for index in range(19):
        response = client.post("/api/v1/eta/profile", headers=headers(index), json=profile())
        assert response.status_code == 200, response.text
    for _ in range(3):
        assert (
            client.post("/api/v1/eta/profile", headers=headers(0), json=profile()).status_code
            == 200
        )
    assert client.get("/api/v1/eta/factors").json()["factors"] == {}
    assert (
        client.post("/api/v1/eta/profile", headers=headers(19), json=profile()).status_code == 200
    )
    result = client.get("/api/v1/eta/factors").json()
    assert result == {"schemaVersion": 1, "minimumContributors": 20, "factors": {"mixed": 0.9}}
    # Wrong identity cannot remove another profile, and deletion is idempotent.
    assert client.delete("/api/v1/eta/profile", headers=headers(99)).status_code == 200
    assert client.get("/api/v1/eta/factors").json() == result
    assert client.delete("/api/v1/eta/profile", headers=headers(19)).status_code == 200
    assert client.get("/api/v1/eta/factors").json()["factors"] == {}
    assert client.delete("/api/v1/eta/profile", headers=headers(19)).status_code == 200


def test_only_bounded_coarse_location_free_payload_is_accepted(client: TestClient):
    for bands in ({"mixed": 0.83}, {"mixed": 1.3}, {"location": 1}):
        response = client.post(
            "/api/v1/eta/profile", headers=headers(0), json={**profile(), "bands": bands}
        )
        assert response.status_code == 400
    assert (
        client.post(
            "/api/v1/eta/profile", headers=headers(0), json={**profile(), "rideId": "private"}
        ).status_code
        == 400
    )
    assert (
        client.post(
            "/api/v1/eta/profile", headers=headers(0), json={**profile(), "latitude": 50}
        ).status_code
        == 400
    )
    assert client.post("/api/v1/eta/profile", json=profile()).status_code == 401
    assert (
        client.post("/api/v1/eta/profile", headers=headers(0), content=b"x" * 1025).status_code
        == 413
    )
    assert client.delete("/api/v1/eta/profile").status_code == 401


def test_retention_deletes_profiles_and_never_stores_credential(client: TestClient):
    assert client.post("/api/v1/eta/profile", headers=headers(1), json=profile()).status_code == 200
    with client.app.state.session_factory() as session:
        row = session.scalar(select(EtaProfile))
        assert row is not None
        assert len(row.credential_hash) == 32
        assert row.bands == {"mixed": 0.8}
        assert row.expires_on == datetime.now(UTC).date() + timedelta(days=90)
        row.expires_on = datetime.now(UTC).date()
        session.commit()
        cleanup_eta(session)
        assert session.scalar(select(EtaProfile)) is None
