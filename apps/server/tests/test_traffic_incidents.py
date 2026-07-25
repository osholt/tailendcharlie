from __future__ import annotations

import asyncio
from datetime import UTC, datetime

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr, ValidationError

from ride_relay_server.app import create_app
from ride_relay_server.config import Settings
from ride_relay_server.traffic import (
    PreferredTrafficProvider,
    TomTomOrbisTrafficProvider,
    TrafficProviderError,
    WazeForCitiesTrafficProvider,
)


class _FakeTrafficProvider:
    def __init__(self):
        self.configured = True
        self.reroute_configured = True
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


_WAZE_FEED_URL = "https://www.waze.com/row-partnerhub-api/partners/1/waze-feeds/token"


def _waze_settings(settings, **overrides):
    return settings.model_copy(
        update={"waze_traffic_feed_url": SecretStr(_WAZE_FEED_URL), **overrides}
    )


def test_waze_provider_normalises_alerts_and_jams_and_caches_one_snapshot(settings):
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert str(request.url) == _WAZE_FEED_URL
        return httpx.Response(
            200,
            json={
                "alerts": [
                    {
                        "uuid": "closure-1",
                        "type": "ROAD_CLOSED",
                        "subtype": "ROAD_CLOSED_EVENT",
                        "street": "A4161",
                        "reportDescription": "Road closed for an event",
                        "location": {"x": -3.18, "y": 51.48},
                        "pubMillis": 1_784_923_080_000,
                        "reliability": 8,
                        "nThumbsUp": 3,
                    },
                    {
                        "uuid": "pothole-1",
                        "type": "HAZARD",
                        "subtype": "HAZARD_ON_ROAD_POT_HOLE",
                        "location": {"x": -3.175, "y": 51.482},
                        "pubMillis": 1_784_923_080_000,
                        "reliability": 7,
                    },
                ],
                "jams": [
                    {
                        "uuid": 7788,
                        "level": 5,
                        "delay": 900,
                        "street": "A470",
                        "line": [
                            {"x": -3.17, "y": 51.49},
                            {"x": -3.16, "y": 51.495},
                        ],
                        "pubMillis": 1_784_923_080_000,
                    }
                ],
            },
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = WazeForCitiesTrafficProvider(
        _waze_settings(settings),
        client=client,
        clock=lambda: datetime(2026, 7, 24, 20, 0, tzinfo=UTC),
    )

    first = asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    second = asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    asyncio.run(client.aclose())

    assert first == second
    assert len(requests) == 1
    assert first["provider"] == "waze-for-cities"
    closure, pothole, jam = first["incidents"]
    assert closure["id"] == "alert-closure-1"
    assert closure["type"] == "roadworks"
    assert closure["severity"] == "critical"
    assert closure["description"] == "Road closed for an event · A4161"
    assert closure["geometry"] == [{"latitude": 51.48, "longitude": -3.18}]
    assert closure["expiresAt"] == "2026-07-24T20:10:00Z"
    assert closure["reportCount"] == 4
    assert pothole["type"] == "pothole"
    assert pothole["severity"] == "caution"
    assert jam["id"] == "jam-7788"
    assert jam["severity"] == "serious"
    assert jam["description"] == "Heavy traffic (Waze level 5) · A470 · 15 min delay"
    assert len(jam["geometry"]) == 2


def test_waze_provider_keeps_enforcement_reports_at_any_confidence(settings):
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "alerts": [
                    {
                        "uuid": "police-1",
                        "type": "POLICE",
                        "subtype": "POLICE_VISIBLE",
                        "street": "A470",
                        "location": {"x": -3.18, "y": 51.48},
                        "reliability": 1,
                    },
                    {
                        "uuid": "camera-1",
                        "type": "HAZARD",
                        "subtype": "HAZARD_ON_ROAD_MOBILE_SPEED_CAMERA",
                        "location": {"x": -3.179, "y": 51.481},
                        "reliability": 0,
                    },
                    {
                        "uuid": "unreliable-pothole",
                        "type": "HAZARD",
                        "subtype": "HAZARD_ON_ROAD_POT_HOLE",
                        "location": {"x": -3.18, "y": 51.48},
                        "reliability": 2,
                    },
                ],
                "jams": [
                    {
                        "uuid": 1,
                        "level": 2,
                        "delay": 30,
                        "line": [{"x": -3.17, "y": 51.49}, {"x": -3.16, "y": 51.495}],
                    }
                ],
            },
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = WazeForCitiesTrafficProvider(
        _waze_settings(settings),
        client=client,
        clock=lambda: datetime(2026, 7, 24, 20, 0, tzinfo=UTC),
    )

    result = asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    asyncio.run(client.aclose())

    police, camera = result["incidents"]
    assert police["id"] == "alert-police-1"
    assert police["type"] == "policeActivity"
    assert police["severity"] == "serious"
    assert police["description"] == "Police reported · A470"
    assert camera["type"] == "speedCamera"
    assert camera["severity"] == "serious"
    # The unreliable pothole and the light jam are still filtered out; only
    # enforcement is exempt from the confidence floor.
    assert len(result["incidents"]) == 2


def test_waze_provider_filters_the_snapshot_to_the_requested_viewport(settings):
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "alerts": [
                    {
                        "uuid": "cardiff",
                        "type": "CONSTRUCTION",
                        "location": {"x": -3.18, "y": 51.48},
                        "reliability": 8,
                    },
                    {
                        "uuid": "glasgow",
                        "type": "CONSTRUCTION",
                        "location": {"x": -4.25, "y": 55.86},
                        "reliability": 8,
                    },
                ]
            },
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = WazeForCitiesTrafficProvider(
        _waze_settings(settings),
        client=client,
        clock=lambda: datetime(2026, 7, 24, 20, 0, tzinfo=UTC),
    )

    result = asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    asyncio.run(client.aclose())

    assert [incident["id"] for incident in result["incidents"]] == ["alert-cardiff"]


def test_waze_provider_offers_no_route_alternative(settings):
    provider = WazeForCitiesTrafficProvider(_waze_settings(settings))

    with pytest.raises(TrafficProviderError):
        asyncio.run(provider.reroute(path=[(51.48, -3.18), (51.49, -3.17)], avoid_areas=[]))
    asyncio.run(provider.close())


def test_preferred_provider_prefers_waze_and_falls_back_to_tomtom(settings):
    waze = _FakeTrafficProvider()
    tomtom = _FakeTrafficProvider()
    provider = PreferredTrafficProvider(preferred=waze, fallback=tomtom)

    asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    assert waze.calls == [(-3.3, 51.3, -2.9, 51.7)]
    assert tomtom.calls == []

    async def unavailable(**_: float) -> dict[str, object]:
        raise TrafficProviderError("Waze feed is unavailable")

    waze.incidents = unavailable
    asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))
    assert tomtom.calls == [(-3.3, 51.3, -2.9, 51.7)]


def test_preferred_provider_surfaces_waze_failure_without_a_fallback(settings):
    waze = _FakeTrafficProvider()
    tomtom = _FakeTrafficProvider()
    tomtom.configured = False
    tomtom.reroute_configured = False

    async def unavailable(**_: float) -> dict[str, object]:
        raise TrafficProviderError("Waze feed is unavailable")

    waze.incidents = unavailable
    provider = PreferredTrafficProvider(preferred=waze, fallback=tomtom)

    with pytest.raises(TrafficProviderError, match="Waze feed is unavailable"):
        asyncio.run(provider.incidents(west=-3.3, south=51.3, east=-2.9, north=51.7))


def test_reroutes_report_unconfigured_when_only_waze_is_configured(settings):
    provider = PreferredTrafficProvider(
        preferred=WazeForCitiesTrafficProvider(_waze_settings(settings)),
        fallback=TomTomOrbisTrafficProvider(settings),
    )

    with TestClient(create_app(settings, traffic_provider=provider)) as client:
        incidents = client.get(
            "/api/v1/traffic/incidents",
            params={"west": -3.3, "south": 51.3, "east": -2.9, "north": 51.7},
        )
        reroute = client.post(
            "/api/v1/traffic/reroutes",
            json={
                "path": [
                    {"latitude": 51.48, "longitude": -3.18},
                    {"latitude": 51.49, "longitude": -3.17},
                ],
                "avoidAreas": [{"west": -3.181, "south": 51.479, "east": -3.179, "north": 51.481}],
                "incidentIds": ["alert-closure-1"],
            },
        )

    assert incidents.status_code == 503
    assert incidents.json()["code"] == "traffic_provider_unavailable"
    assert reroute.status_code == 503
    assert reroute.json() == {
        "code": "traffic_provider_unconfigured",
        "message": "Live UK traffic rerouting is not configured.",
    }


def test_waze_feed_url_must_be_an_https_waze_host(settings):
    base = {
        "environment": "test",
        "database_url": settings.database_url,
        "data_encryption_key": settings.data_encryption_key.get_secret_value(),
        "cursor_signing_key": settings.cursor_signing_key.get_secret_value(),
    }

    with pytest.raises(ValidationError):
        Settings(**base, waze_traffic_feed_url="http://www.waze.com/feed")
    with pytest.raises(ValidationError):
        Settings(**base, waze_traffic_feed_url="https://example.com/feed")

    accepted = Settings(**base, waze_traffic_feed_url=_WAZE_FEED_URL)
    assert accepted.waze_traffic_feed_url is not None
    assert accepted.waze_traffic_feed_url.get_secret_value() == _WAZE_FEED_URL
    assert "token" not in str(accepted.waze_traffic_feed_url)
