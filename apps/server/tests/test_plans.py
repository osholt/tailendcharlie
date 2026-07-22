from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from ride_relay_server.app import create_app
from ride_relay_server.gpx import GpxValidationError, validate_gpx
from ride_relay_server.models import RidePlan
from ride_relay_server.service import PLAN_CODE_ALPHABET, PLAN_CODE_LENGTH, purge_expired

GPX_TWO_POINTS = """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1"><trk><name>Loop</name><trkseg>
<trkpt lat="51.5" lon="-0.1"></trkpt>
<trkpt lat="51.6" lon="-0.2"></trkpt>
</trkseg></trk></gpx>"""


def _create(client, *, name: str | None = "Sunday loop", gpx: str = GPX_TWO_POINTS):
    body: dict[str, str] = {"gpx": gpx}
    if name is not None:
        body["name"] = name
    return client.post("/api/v1/plans", json=body)


class TestValidateGpx:
    def test_valid_gpx_returns_point_count(self) -> None:
        assert validate_gpx(GPX_TWO_POINTS, maximum_bytes=1_000_000, maximum_points=1000) == 2

    def test_rejects_empty(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx("", maximum_bytes=1_000_000, maximum_points=1000)

    def test_rejects_oversized(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx(GPX_TWO_POINTS, maximum_bytes=10, maximum_points=1000)

    def test_rejects_doctype(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx(
                '<?xml version="1.0"?><!DOCTYPE gpx [<!ENTITY x "y">]><gpx></gpx>',
                maximum_bytes=1_000_000,
                maximum_points=1000,
            )

    def test_rejects_malformed_xml(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx("<gpx><trk>", maximum_bytes=1_000_000, maximum_points=1000)

    def test_rejects_wrong_root(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx("<kml></kml>", maximum_bytes=1_000_000, maximum_points=1000)

    def test_rejects_empty_geometry(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx("<gpx></gpx>", maximum_bytes=1_000_000, maximum_points=1000)

    def test_rejects_out_of_range_coordinate(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx(
                '<gpx><trk><trkseg><trkpt lat="500" lon="-0.1"></trkpt></trkseg></trk></gpx>',
                maximum_bytes=1_000_000,
                maximum_points=1000,
            )

    def test_rejects_over_point_limit(self) -> None:
        with pytest.raises(GpxValidationError):
            validate_gpx(GPX_TWO_POINTS, maximum_bytes=1_000_000, maximum_points=1)

    def test_counts_routes_and_waypoints_too(self) -> None:
        gpx = '<gpx><rte><rtept lat="1" lon="1"></rtept></rte><wpt lat="2" lon="2"></wpt></gpx>'
        assert validate_gpx(gpx, maximum_bytes=1_000_000, maximum_points=1000) == 2


def test_create_and_fetch_plan_round_trips(client) -> None:
    created = _create(client)
    assert created.status_code == 200
    body = created.json()
    assert len(body["code"]) == PLAN_CODE_LENGTH
    assert set(body["code"]) <= set(PLAN_CODE_ALPHABET)

    fetched = client.get(f"/api/v1/plans/{body['code']}")
    assert fetched.status_code == 200
    assert fetched.json()["gpx"] == GPX_TWO_POINTS
    assert fetched.json()["name"] == "Sunday loop"


def test_plan_without_a_name_round_trips(client) -> None:
    created = _create(client, name=None)
    assert created.status_code == 200

    fetched = client.get(f"/api/v1/plans/{created.json()['code']}")
    assert fetched.json()["name"] is None


def test_unknown_plan_code_is_not_found(client) -> None:
    assert client.get("/api/v1/plans/ZZZZZZZZ").status_code == 404


def test_malformed_plan_code_is_not_found(client) -> None:
    assert client.get("/api/v1/plans/not-a-valid-code!!").status_code == 404


def test_create_rejects_invalid_gpx(client) -> None:
    response = _create(client, gpx="<kml></kml>")
    assert response.status_code == 400


def test_create_rejects_overlong_name(client) -> None:
    response = _create(client, name="x" * 201)
    assert response.status_code == 400


def test_plan_gpx_is_encrypted_at_rest(client) -> None:
    created = _create(client)
    factory = client.app.state.session_factory
    with factory() as session:
        stored = session.get(RidePlan, created.json()["code"])
        assert stored is not None
        assert b"51.5" not in stored.gpx_ciphertext
        assert b"Loop" not in stored.gpx_ciphertext


def test_expired_plan_is_not_found_and_purge_removes_it(client) -> None:
    created = _create(client)
    code = created.json()["code"]
    factory = client.app.state.session_factory
    with factory() as session:
        plan = session.get(RidePlan, code)
        plan.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.commit()

    assert client.get(f"/api/v1/plans/{code}").status_code == 404

    with factory() as session:
        purge_expired(session)
    with factory() as session:
        assert session.get(RidePlan, code) is None


def test_plan_create_is_rate_limited(settings) -> None:
    limited = settings.model_copy(update={"plan_create_rate_limit_requests": 1})
    with TestClient(create_app(limited)) as client:
        assert _create(client).status_code == 200
        assert _create(client).status_code == 429


def test_plan_lookup_is_rate_limited(settings) -> None:
    limited = settings.model_copy(update={"plan_lookup_rate_limit_requests": 1})
    with TestClient(create_app(limited)) as client:
        created = _create(client)
        code = created.json()["code"]
        assert client.get(f"/api/v1/plans/{code}").status_code == 200
        assert client.get(f"/api/v1/plans/{code}").status_code == 429


def test_oversized_plan_upload_is_rejected(settings) -> None:
    tiny = settings.model_copy(update={"maximum_plan_bytes": 64})
    with TestClient(create_app(tiny)) as client:
        response = _create(client)
        assert response.status_code == 413
