from __future__ import annotations

import asyncio
from datetime import UTC, datetime

import httpx
from fastapi.testclient import TestClient
from pydantic import SecretStr

from ride_relay_server.app import create_app
from ride_relay_server.traffic import TomTomOrbisTrafficProvider


class _FakeTrafficProvider:
    def __init__(self):
        self.configured = True
        self.calls: list[tuple[float, float, float, float]] = []
        self.closed = False

    async def incidents(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]:
        self.calls.append((west, south, east, north))
        return {
            "provider": "synthetic",
            "fetchedAt": "2026-07-24T20:00:00Z",
            "trafficModelId": "123",
            "incidents": [],
        }

    async def reroute(
        self,
        *,
        path: list[tuple[float, float]],
        avoid_areas: list[tuple[float, float, float, float]],
    ) -> dict[str, object]:
        self.reroute_call = (path, avoid_areas)
        return {
            "provider": "synthetic",
            "calculatedAt": "2026-07-24T20:00:00Z",
            "reference": {
                "distanceMeters": 1000,
                "travelDurationSeconds": 120,
                "trafficDelaySeconds": 60,
                "points": [
                    {"latitude": 51.48, "longitude": -3.18},
                    {"latitude": 51.49, "longitude": -3.17},
                ],
            },
            "alternative": {
                "distanceMeters": 1200,
                "travelDurationSeconds": 100,
                "trafficDelaySeconds": 0,
                "deviationDistanceMeters": 250,
                "deviationDurationSeconds": 20,
                "points": [
                    {"latitude": 51.48, "longitude": -3.18},
                    {"latitude": 51.485, "longitude": -3.16},
                    {"latitude": 51.49, "longitude": -3.17},
                ],
            },
        }

    async def close(self) -> None:
        self.closed = True


def test_incident_proxy_is_explicit_when_provider_is_unconfigured(client):
    response = client.get(
        "/api/v1/traffic/incidents",
        params={"west": -3.3, "south": 51.3, "east": -2.9, "north": 51.7},
    )

    assert response.status_code == 503
    assert response.json() == {
        "code": "traffic_provider_unconfigured",
        "message": "Live UK traffic incidents are not configured.",
    }


def test_incident_proxy_rejects_non_uk_and_excessive_viewports(client):
    outside = client.get(
        "/api/v1/traffic/incidents",
        params={"west": 4.8, "south": 52.2, "east": 5.0, "north": 52.4},
    )
    too_large = client.get(
        "/api/v1/traffic/incidents",
        params={"west": -8, "south": 50, "east": 2, "north": 60},
    )

    assert outside.status_code == 400
    assert outside.json() == {
        "error": "Traffic incidents are currently available only for UK routes"
    }
    assert too_large.status_code == 400
    assert too_large.json() == {"error": "Traffic viewport exceeds the provider area limit"}


def test_incident_proxy_returns_provider_data_and_closes_it(settings):
    provider = _FakeTrafficProvider()

    with TestClient(create_app(settings, traffic_provider=provider)) as client:
        response = client.get(
            "/api/v1/traffic/incidents",
            params={"west": -3.3, "south": 51.3, "east": -2.9, "north": 51.7},
        )

    assert response.status_code == 200
    assert response.json()["provider"] == "synthetic"
    assert provider.calls == [(-3.3, 51.3, -2.9, 51.7)]
    assert provider.closed


def test_reroute_proxy_is_explicit_when_provider_is_unconfigured(client):
    response = client.post(
        "/api/v1/traffic/reroutes",
        json={
            "path": [
                {"latitude": 51.48, "longitude": -3.18},
                {"latitude": 51.49, "longitude": -3.17},
            ],
            "avoidAreas": [
                {
                    "west": -3.181,
                    "south": 51.479,
                    "east": -3.179,
                    "north": 51.481,
                }
            ],
            "incidentIds": ["closure-1"],
        },
    )

    assert response.status_code == 503
    assert response.json() == {
        "code": "traffic_provider_unconfigured",
        "message": "Live UK traffic rerouting is not configured.",
    }


def test_reroute_proxy_returns_a_bounded_leader_preview(settings):
    provider = _FakeTrafficProvider()
    payload = {
        "path": [
            {"latitude": 51.48, "longitude": -3.18},
            {"latitude": 51.49, "longitude": -3.17},
        ],
        "avoidAreas": [
            {
                "west": -3.181,
                "south": 51.479,
                "east": -3.179,
                "north": 51.481,
            }
        ],
        "incidentIds": ["closure-1"],
    }

    with TestClient(create_app(settings, traffic_provider=provider)) as client:
        response = client.post("/api/v1/traffic/reroutes", json=payload)

    assert response.status_code == 200
    assert response.json()["incidentIds"] == ["closure-1"]
    assert response.json()["alternative"]["travelDurationSeconds"] == 100
    assert provider.reroute_call == (
        [(51.48, -3.18), (51.49, -3.17)],
        [(-3.181, 51.479, -3.179, 51.481)],
    )


def test_reroute_proxy_rejects_oversized_avoid_area(settings):
    provider = _FakeTrafficProvider()
    with TestClient(create_app(settings, traffic_provider=provider)) as client:
        response = client.post(
            "/api/v1/traffic/reroutes",
            json={
                "path": [
                    {"latitude": 51.48, "longitude": -3.18},
                    {"latitude": 51.49, "longitude": -3.17},
                ],
                "avoidAreas": [
                    {
                        "west": -3.3,
                        "south": 51.3,
                        "east": -2.9,
                        "north": 51.7,
                    }
                ],
                "incidentIds": ["closure-1"],
            },
        )

    assert response.status_code == 400
    assert response.json() == {"error": "A traffic reroute avoid area is too large"}


def test_tomtom_provider_uses_header_key_normalises_and_caches(settings):
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.headers["tomtom-api-key"] == "server-held-secret"
        assert "key=" not in str(request.url)
        assert request.url.params["apiVersion"] == "2"
        return httpx.Response(
            200,
            headers={"TrafficModelID": "99123"},
            json={
                "incidents": [
                    {
                        "type": "Feature",
                        "geometry": {
                            "type": "LineString",
                            "coordinates": [
                                [-3.1800, 51.4800],
                                [-3.1750, 51.4820],
                            ],
                        },
                        "properties": {
                            "id": "closure-1",
                            "iconCategory": "roadClosed",
                            "magnitudeOfDelay": "undefined",
                            "events": [
                                {
                                    "description": "Road closed",
                                    "code": 401,
                                    "iconCategory": "roadClosed",
                                }
                            ],
                            "startTime": "2026-07-24T19:00:00Z",
                            "endTime": "2026-07-25T01:00:00Z",
                            "from": "A4161",
                            "to": "Newport Road",
                            "delayInSeconds": 0,
                            "roadNumbers": ["A4161"],
                            "probabilityOfOccurrence": "certain",
                            "numberOfReports": 4,
                            "lastReportTime": "2026-07-24T19:58:00Z",
                        },
                    }
                ]
            },
        )

    configured = settings.model_copy(
        update={"tomtom_traffic_api_key": SecretStr("server-held-secret")}
    )
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = TomTomOrbisTrafficProvider(
        configured,
        client=client,
        clock=lambda: datetime(2026, 7, 24, 20, 0, tzinfo=UTC),
    )

    first = asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    second = asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    asyncio.run(client.aclose())

    assert first == second
    assert len(requests) == 1
    assert first["trafficModelId"] == "99123"
    incident = first["incidents"][0]
    assert incident["id"] == "closure-1"
    assert incident["type"] == "roadworks"
    assert incident["severity"] == "critical"
    assert incident["description"] == "Road closed · A4161 · A4161 to Newport Road"
    assert incident["geometry"] == [
        {"latitude": 51.48, "longitude": -3.18},
        {"latitude": 51.482, "longitude": -3.175},
    ]
    assert incident["observedAt"] == "2026-07-24T19:58:00Z"
    assert incident["expiresAt"] == "2026-07-24T20:15:00Z"
    assert incident["direction"] == {"from": "A4161", "to": "Newport Road"}


def test_tomtom_provider_requests_and_selects_a_path_alternative(settings):
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.method == "POST"
        assert request.headers["tomtom-api-key"] == "server-held-secret"
        assert request.headers["attributes"].startswith("routes(summary")
        assert request.url.params["apiVersion"] == "3"
        body = request.read().decode()
        assert '"maxPathAlternativeRoutes":2' in body
        assert '"avoidAreas"' in body
        return httpx.Response(
            200,
            json={
                "routes": [
                    {
                        "summary": {
                            "lengthInMeters": 1000,
                            "travelDurationInSeconds": 180,
                            "trafficDelayDurationInSeconds": 90,
                        },
                        "legs": [
                            {
                                "path": {
                                    "type": "LineString",
                                    "coordinates": [
                                        [-3.18, 51.48],
                                        [-3.17, 51.49],
                                    ],
                                }
                            }
                        ],
                    },
                    {
                        "summary": {
                            "lengthInMeters": 1200,
                            "travelDurationInSeconds": 140,
                            "trafficDelayDurationInSeconds": 0,
                            "deviationDistanceInMeters": 250,
                            "deviationDurationInSeconds": 20,
                        },
                        "legs": [
                            {
                                "path": {
                                    "type": "LineString",
                                    "coordinates": [
                                        [-3.18, 51.48],
                                        [-3.16, 51.485],
                                        [-3.17, 51.49],
                                    ],
                                }
                            }
                        ],
                        "instructions": [
                            {
                                "maneuver": "turnRight",
                                "maneuverPoint": {
                                    "latitude": 51.485,
                                    "longitude": -3.16,
                                },
                                "nextRoadInformation": {
                                    "streetName": {"text": "Newport Road"},
                                    "roadShields": [{"roadNumber": {"text": "A4161"}}],
                                },
                                "drivingSide": "left",
                                "message": "Turn right onto Newport Road.",
                            }
                        ],
                    },
                ]
            },
        )

    configured = settings.model_copy(
        update={"tomtom_traffic_api_key": SecretStr("server-held-secret")}
    )
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = TomTomOrbisTrafficProvider(
        configured,
        client=client,
        clock=lambda: datetime(2026, 7, 24, 20, 0, tzinfo=UTC),
    )

    result = asyncio.run(
        provider.reroute(
            path=[(51.48, -3.18), (51.49, -3.17)],
            avoid_areas=[(-3.181, 51.479, -3.179, 51.481)],
        )
    )
    asyncio.run(client.aclose())

    assert len(requests) == 1
    assert result["provider"] == "tomtom-orbis"
    assert result["reference"]["trafficDelaySeconds"] == 90
    assert result["alternative"]["distanceMeters"] == 1200
    assert result["alternative"]["travelDurationSeconds"] == 140
    assert result["alternative"]["points"][1] == {
        "latitude": 51.485,
        "longitude": -3.16,
    }
    assert result["alternative"]["maneuvers"] == [
        {
            "latitude": 51.485,
            "longitude": -3.16,
            "type": "turn",
            "modifier": "right",
            "name": "Newport Road",
            "ref": "A4161",
            "drivingSide": "left",
            "message": "Turn right onto Newport Road.",
        }
    ]
