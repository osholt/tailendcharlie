"""Charger capability and bounded proxy failure behavior; no provider requests."""

import asyncio
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from ride_relay_server.app import create_app
from ride_relay_server.config import Settings

BOUNDS = {"west": -1.8, "south": 51.8, "east": -1.2, "north": 52.2}


def test_unconfigured_has_no_capability_and_returns_503(client):
    assert "charging-status-v1" not in client.get("/api/v1/compatibility").json()["capabilities"]
    assert client.get("/api/v1/charging/locations", params=BOUNDS).status_code == 503


def test_configured_proxy_does_not_change_observation_times(settings, monkeypatch):
    payload = {
        "schemaVersion": 1,
        "locations": [],
        "sources": [{"checkedAt": 123}],
        "generatedAt": 456,
    }
    fetch = AsyncMock(return_value=payload)
    monkeypatch.setattr("ride_relay_server.app.charger_viewport", fetch)
    configured = settings.model_copy(
        update={"charging_collector_url": "https://routing.example/charging/v1/chargers"}
    )
    with TestClient(create_app(configured)) as client:
        assert "charging-status-v1" in client.get("/api/v1/compatibility").json()["capabilities"]
        result = client.get("/api/v1/charging/locations", params=BOUNDS)
        assert result.status_code == 200
        assert result.json() == payload
        assert fetch.call_args.args[1] == BOUNDS
        result = client.get("/api/v1/charging/locations", params={**BOUNDS, "east": 3})
        assert result.status_code == 400
        assert fetch.call_count == 1
        fetch.side_effect = ValueError("private upstream details")
        result = client.get("/api/v1/charging/locations", params=BOUNDS)
        assert result.status_code == 503
        assert "private" not in result.text


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com",
        "https://u:p@example.com",
        "https://example.com/?key=x",
        "http://charging:8090/other",
        "http://charging:8090/v1/chargers?url=x",
    ],
)
def test_collector_url_requires_fixed_https(url):
    with pytest.raises(ValueError):
        Settings.validate_charging_collector_url(url)


@pytest.mark.parametrize("mode", ["ok", "redirect", "large", "encoded", "schema"])
def test_upstream_is_bounded_and_redirects_are_not_followed(monkeypatch, mode):
    import httpx

    from ride_relay_server import charging

    calls = []

    def handle(request):
        calls.append(request)
        if mode == "redirect":
            return httpx.Response(302, headers={"Location": "https://elsewhere.example"})
        if mode == "large":
            return httpx.Response(
                200,
                json={
                    "schemaVersion": 1,
                    "locations": [],
                    "sources": [],
                    "padding": " " * charging.MAX_BYTES,
                },
            )
        if mode == "encoded":
            return httpx.Response(200, headers={"Content-Encoding": "unexpected"})
        return httpx.Response(
            200,
            json={
                "schemaVersion": 2 if mode == "schema" else 1,
                "locations": [],
                "sources": [],
            },
        )

    original = httpx.AsyncClient
    monkeypatch.setattr(
        charging.httpx,
        "AsyncClient",
        lambda **kwargs: original(**kwargs, transport=httpx.MockTransport(handle)),
    )
    if mode == "ok":
        assert (asyncio.run(charging.charger_viewport("https://routing.example", BOUNDS)))[
            "locations"
        ] == []
    else:
        with pytest.raises((ValueError, httpx.HTTPError)):
            asyncio.run(charging.charger_viewport("https://routing.example", BOUNDS))
    assert len(calls) == 1


def test_collector_accepts_exact_internal_service():
    assert (
        Settings.validate_charging_collector_url("http://charging:8090/v1/chargers")
        == "http://charging:8090/v1/chargers"
    )
