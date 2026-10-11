"""Fuel price ingest, cache and viewport API (#951).

No test reaches the network: Fuel Finder is answered from schema-derived
fixtures and prix-carburants from a recorded excerpt, both in
`tests/fixtures/fuel/` (see the README there).
"""

from __future__ import annotations

import asyncio
import io
import json
import zipfile
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from ride_relay_server.app import create_app
from ride_relay_server.config import Settings
from ride_relay_server.fuel import (
    FR_SOURCE_ID,
    FUEL_PRICES_CAPABILITY,
    UK_SOURCE_ID,
    FuelFinderSource,
    FuelPrice,
    FuelPriceError,
    FuelPriceService,
    FuelStation,
    PrixCarburantsSource,
    SourceSnapshot,
    paris_local_to_utc,
    parse_prix_carburants,
)

FIXTURES = Path(__file__).parent / "fixtures" / "fuel"
START = datetime(2026, 10, 10, 8, 0, tzinfo=UTC)


def _fixture(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


class _Clock:
    def __init__(self, now: datetime = START):
        self.now = now

    def __call__(self) -> datetime:
        return self.now


class _Sleeps:
    def __init__(self, clock: _Clock | None = None):
        self.waits: list[float] = []
        self._clock = clock

    async def __call__(self, seconds: float) -> None:
        self.waits.append(seconds)
        if self._clock is not None:
            self._clock.now += timedelta(seconds=seconds)


def _uk_settings(settings: Settings, **overrides: object) -> Settings:
    return settings.model_copy(
        update={
            "fuel_finder_client_id": "synthetic-client",
            "fuel_finder_client_secret": SecretStr("synthetic-secret"),
            **overrides,
        }
    )


class _FuelFinderServer:
    """Answers the Fuel Finder paths from fixtures and records every request."""

    def __init__(self, *, incremental: bytes | None = None):
        self.requests: list[httpx.Request] = []
        self.incremental = incremental
        self.price_status: int | None = None

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        batch = request.url.params.get("batch-number")
        if path == "/api/v1/oauth/generate_access_token":
            return httpx.Response(200, content=_fixture("fuel_finder_token.json"))
        if path == "/api/v1/pfs":
            if batch == "1":
                return httpx.Response(200, content=_fixture("fuel_finder_stations_batch_1.json"))
            if batch == "2":
                return httpx.Response(200, content=_fixture("fuel_finder_stations_batch_2.json"))
            return httpx.Response(404, json={"message": "batch not found"})
        if path == "/api/v1/pfs/fuel-prices":
            if self.price_status is not None:
                return httpx.Response(self.price_status, json={"message": "unavailable"})
            if "effective-start-timestamp" in request.url.params:
                if batch == "1" and self.incremental is not None:
                    return httpx.Response(200, content=self.incremental)
                return httpx.Response(200, json=[])
            if batch == "1":
                return httpx.Response(200, content=_fixture("fuel_finder_prices_batch_1.json"))
            if batch == "2":
                return httpx.Response(200, content=_fixture("fuel_finder_prices_batch_2.json"))
            return httpx.Response(200, json={"success": True, "data": []})
        return httpx.Response(500)

    def paths(self) -> list[str]:
        return [request.url.path for request in self.requests]


def _uk_source(
    settings: Settings,
    server: _FuelFinderServer,
    clock: _Clock,
    sleeps: _Sleeps,
) -> tuple[FuelFinderSource, httpx.AsyncClient]:
    client = httpx.AsyncClient(transport=httpx.MockTransport(server.handler))
    source = FuelFinderSource(_uk_settings(settings), client=client, clock=clock, sleep=sleeps)
    return source, client


def test_fuel_finder_full_load_reads_every_batch_and_keeps_only_usable_prices(settings):
    server = _FuelFinderServer()
    clock = _Clock()
    sleeps = _Sleeps(clock)

    async def scenario() -> SourceSnapshot:
        source, client = _uk_source(settings, server, clock, sleeps)
        async with client:
            return await source.refresh(SourceSnapshot())

    snapshot = asyncio.run(scenario())

    assert sorted(snapshot.stations) == ["uk:0001aaaa", "uk:0002bbbb", "uk:0004dddd"]
    north = snapshot.stations["uk:0001aaaa"]
    assert (north.latitude, north.longitude) == (52.1, -1.9)
    assert north.name == "Example Services North"
    assert north.brand == "EXAMPLE"
    assert north.closed is False
    # E10 and E5 kept with their own timestamps, unaltered. The diesel price
    # keyed in pounds (1.499) is dropped rather than multiplied up, and HVO is
    # not a grade a rider can choose.
    assert north.prices == {
        "e10": FuelPrice(
            142.9,
            reported_at=datetime(2026, 10, 9, 7, 15, tzinfo=UTC),
            effective_at=datetime(2026, 10, 9, 7, 0, tzinfo=UTC),
        ),
        "e5": FuelPrice(
            158.9,
            reported_at=datetime(2026, 10, 1, 6, 0, tzinfo=UTC),
            effective_at=datetime(2026, 10, 1, 5, 45, tzinfo=UTC),
        ),
    }
    assert snapshot.stations["uk:0002bbbb"].closed is True
    assert snapshot.stations["uk:0002bbbb"].prices["diesel"].minor_per_litre == 144.7
    village = snapshot.stations["uk:0004dddd"]
    assert village.brand is None
    # A zero price is a placeholder, not a free tank.
    assert set(village.prices) == {"e10", "dieselPremium"}
    assert snapshot.checked_at == clock.now


def test_fuel_finder_authenticates_once_in_the_body_and_paces_serial_requests(settings):
    server = _FuelFinderServer()
    clock = _Clock()
    sleeps = _Sleeps(clock)

    async def scenario() -> None:
        source, client = _uk_source(settings, server, clock, sleeps)
        async with client:
            await source.refresh(SourceSnapshot())

    asyncio.run(scenario())

    token_requests = [r for r in server.requests if r.method == "POST"]
    assert len(token_requests) == 1
    form = parse_qs(token_requests[0].content.decode())
    assert form["grant_type"] == ["client_credentials"]
    assert form["client_id"] == ["synthetic-client"]
    assert form["client_secret"] == ["synthetic-secret"]
    assert form["scope"] == ["fuelfinder.read"]
    for request in server.requests:
        assert "synthetic-secret" not in str(request.url)
    for request in server.requests[1:]:
        assert request.headers["authorization"] == "Bearer synthetic-access-token"
    # Every request after the first waited out the full interval, because the
    # scheme allows one request at a time and a per-minute ceiling.
    assert len(sleeps.waits) == len(server.requests) - 1
    assert all(wait == pytest.approx(3.0) for wait in sleeps.waits)
    assert server.paths() == [
        "/api/v1/oauth/generate_access_token",
        "/api/v1/pfs",
        "/api/v1/pfs",
        "/api/v1/pfs",
        "/api/v1/pfs/fuel-prices",
        "/api/v1/pfs/fuel-prices",
        "/api/v1/pfs/fuel-prices",
    ]


def test_fuel_finder_asks_only_for_changes_between_full_loads(settings):
    server = _FuelFinderServer(incremental=_fixture("fuel_finder_prices_incremental.json"))
    clock = _Clock()
    sleeps = _Sleeps()

    async def scenario() -> tuple[SourceSnapshot, SourceSnapshot]:
        source, client = _uk_source(settings, server, clock, sleeps)
        async with client:
            first = await source.refresh(SourceSnapshot())
            server.requests.clear()
            clock.now = START + timedelta(minutes=15)
            second = await source.refresh(first)
            return first, second

    first, second = asyncio.run(scenario())

    # No station list and no token: both are still fresh.
    assert server.paths() == ["/api/v1/pfs/fuel-prices", "/api/v1/pfs/fuel-prices"]
    # Changes since the previous check, reaching back 45 minutes to cover a
    # forecourt's 30-minute reporting window and the API's 5 minutes.
    assert server.requests[0].url.params["effective-start-timestamp"] == "2026-10-10 07:15:00"
    north = second.stations["uk:0001aaaa"]
    assert north.prices["e10"].minor_per_litre == 141.9
    assert north.prices["e10"].reported_at == datetime(2026, 10, 10, 8, 5, tzinfo=UTC)
    # Grades the change did not mention keep their earlier prices.
    assert north.prices["e5"] == first.stations["uk:0001aaaa"].prices["e5"]
    assert second.stations["uk:0004dddd"].prices == first.stations["uk:0004dddd"].prices
    assert second.checked_at == START + timedelta(minutes=15)


def test_fuel_finder_reloads_everything_after_a_day(settings):
    server = _FuelFinderServer()
    clock = _Clock()

    async def scenario() -> None:
        source, client = _uk_source(settings, server, clock, _Sleeps())
        async with client:
            first = await source.refresh(SourceSnapshot())
            server.requests.clear()
            clock.now = START + timedelta(hours=24)
            await source.refresh(first)

    asyncio.run(scenario())

    price_requests = [r for r in server.requests if r.url.path == "/api/v1/pfs/fuel-prices"]
    assert price_requests
    assert all("effective-start-timestamp" not in r.url.params for r in price_requests)
    # The token outlived its hour and the station list its hour.
    assert server.paths()[0] == "/api/v1/oauth/generate_access_token"
    assert "/api/v1/pfs" in server.paths()


def test_fuel_finder_reloads_the_station_list_hourly(settings):
    # The developer guidelines cache station data for at most an hour, so a
    # forecourt's closure reaches riders within it.
    server = _FuelFinderServer()
    clock = _Clock()

    async def scenario() -> None:
        source, client = _uk_source(settings, server, clock, _Sleeps())
        async with client:
            first = await source.refresh(SourceSnapshot())
            server.requests.clear()
            clock.now = START + timedelta(minutes=61)
            await source.refresh(first)

    asyncio.run(scenario())

    assert "/api/v1/pfs" in server.paths()


def test_prices_are_checked_at_least_every_five_minutes(settings):
    # Fuel Finder's Fair Use policy for services shown to the public.
    assert settings.fuel_price_refresh_seconds <= 300
    with pytest.raises(ValueError, match="less than or equal to 300"):
        Settings(
            **{
                **settings.model_dump(),
                "data_encryption_key": settings.data_encryption_key.get_secret_value(),
                "cursor_signing_key": settings.cursor_signing_key.get_secret_value(),
                "fuel_price_refresh_seconds": 900,
            }
        )


def test_a_failed_refresh_keeps_the_previous_snapshot_and_its_check_time(settings):
    server = _FuelFinderServer()
    clock = _Clock()

    async def scenario() -> tuple[dict, dict]:
        client = httpx.AsyncClient(transport=httpx.MockTransport(server.handler))
        source = FuelFinderSource(
            _uk_settings(settings), client=client, clock=clock, sleep=_Sleeps()
        )
        service = FuelPriceService(_uk_settings(settings), sources=[source], clock=clock)
        async with client:
            assert await service.refresh_once(source) is True
            before = service.viewport(west=-2.2, south=51.9, east=-1.4, north=52.4)
            server.price_status = 429
            clock.now = START + timedelta(minutes=15)
            assert await service.refresh_once(source) is False
            after = service.viewport(west=-2.2, south=51.9, east=-1.4, north=52.4)
            return before, after

    before, after = asyncio.run(scenario())

    assert after["stations"] == before["stations"]
    # The relay does not pretend it confirmed the source again.
    assert after["sources"][0]["checkedAt"] == "2026-10-10T08:00:00Z"


def test_fuel_finder_rejects_an_unrecognised_response_shape(settings):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST":
            return httpx.Response(200, content=_fixture("fuel_finder_token.json"))
        return httpx.Response(200, json={"stations": []})

    async def scenario() -> None:
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        source = FuelFinderSource(_uk_settings(settings), client=client, sleep=_Sleeps())
        async with client:
            await source.refresh(SourceSnapshot())

    with pytest.raises(FuelPriceError, match="unexpected response shape"):
        asyncio.run(scenario())


def test_fuel_finder_needs_both_credentials(settings):
    client = httpx.AsyncClient()
    assert FuelFinderSource(settings, client=client).configured is False
    only_id = settings.model_copy(update={"fuel_finder_client_id": "synthetic-client"})
    assert FuelFinderSource(only_id, client=client).configured is False
    assert FuelFinderSource(_uk_settings(settings), client=client).configured is True
    asyncio.run(client.aclose())


def test_an_empty_secret_in_the_environment_is_no_secret(settings):
    reloaded = Settings(
        **{
            **settings.model_dump(),
            "data_encryption_key": settings.data_encryption_key.get_secret_value(),
            "cursor_signing_key": settings.cursor_signing_key.get_secret_value(),
            "fuel_finder_client_secret": "",
        }
    )
    assert reloaded.fuel_finder_client_secret is None


def test_a_fuel_source_must_be_https(settings):
    with pytest.raises(ValueError, match="https"):
        Settings(
            **{
                **settings.model_dump(),
                "data_encryption_key": settings.data_encryption_key.get_secret_value(),
                "cursor_signing_key": settings.cursor_signing_key.get_secret_value(),
                "fuel_finder_base_url": "http://www.fuel-finder.service.gov.uk",
            }
        )


def test_prix_carburants_excerpt_is_read_in_degrees_euro_cents_and_utc():
    stations = parse_prix_carburants(
        _fixture("prix_carburants_instantane_excerpt.xml"), maximum_stations=10
    )

    assert sorted(stations) == ["fr:58240003", "fr:80570001", "fr:89100001"]
    first = stations["fr:89100001"]
    assert first.source == FR_SOURCE_ID
    assert (first.latitude, first.longitude) == pytest.approx((48.183, 3.309))
    assert first.name is None
    # Gazole is diesel, E10 is E10 and SP98 is super unleaded. E85 is not a
    # grade a rider can choose, and SP95 (on the second station) is neither E10
    # nor super unleaded, so neither is shown as one.
    assert first.prices == {
        "diesel": FuelPrice(238.9, reported_at=datetime(2026, 10, 6, 12, 40, 28, tzinfo=UTC)),
        "e10": FuelPrice(220.9, reported_at=datetime(2026, 9, 28, 9, 45, 27, tzinfo=UTC)),
        "e5": FuelPrice(228.9, reported_at=datetime(2026, 9, 28, 9, 42, 0, tzinfo=UTC)),
    }
    assert set(stations["fr:80570001"].prices) == {"diesel", "e5"}
    third = stations["fr:58240003"]
    assert third.latitude == pytest.approx(46.7535171497)
    assert third.prices == {}


def test_a_french_station_selling_only_sp95_has_no_super_unleaded_price():
    xml = (
        b'<?xml version="1.0" encoding="ISO-8859-1"?><pdv_liste>'
        b'<pdv id="1" latitude="4800000" longitude="200000">'
        b'<prix nom="SP95" maj="2026-10-01 10:00:00" valeur="1.999"/>'
        b"</pdv></pdv_liste>"
    )

    (station,) = parse_prix_carburants(xml, maximum_stations=10).values()

    assert station.prices == {}


@pytest.mark.parametrize(
    ("local", "utc"),
    [
        (datetime(2026, 12, 1, 10, 0), datetime(2026, 12, 1, 9, 0, tzinfo=UTC)),
        (datetime(2026, 7, 1, 10, 0), datetime(2026, 7, 1, 8, 0, tzinfo=UTC)),
        # Summer time starts at 01:00 UTC on 29 March 2026: 02:00 local becomes 03:00.
        (datetime(2026, 3, 29, 1, 30), datetime(2026, 3, 29, 0, 30, tzinfo=UTC)),
        (datetime(2026, 3, 29, 3, 30), datetime(2026, 3, 29, 1, 30, tzinfo=UTC)),
        # And ends at 01:00 UTC on 25 October 2026.
        (datetime(2026, 10, 25, 4, 0), datetime(2026, 10, 25, 3, 0, tzinfo=UTC)),
        (datetime(2026, 10, 24, 23, 0), datetime(2026, 10, 24, 21, 0, tzinfo=UTC)),
    ],
)
def test_french_local_time_follows_the_eu_summer_time_rule(local, utc):
    assert paris_local_to_utc(local) == utc


def _zip(*members: tuple[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for name, data in members:
            bundle.writestr(name, data)
    return buffer.getvalue()


def _france_settings(settings: Settings) -> Settings:
    return settings.model_copy(update={"fuel_prices_france_enabled": True})


def _run_france(
    settings: Settings,
    handler: Callable[[httpx.Request], httpx.Response],
    *snapshots: SourceSnapshot,
    clock: _Clock | None = None,
) -> list[SourceSnapshot | Exception]:
    clock = clock or _Clock()

    async def scenario() -> list[SourceSnapshot | Exception]:
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        source = PrixCarburantsSource(_france_settings(settings), client=client, clock=clock)
        results: list[SourceSnapshot | Exception] = []
        async with client:
            previous = snapshots[0] if snapshots else SourceSnapshot()
            for _ in range(max(1, len(snapshots))):
                try:
                    previous = await source.refresh(previous)
                    results.append(previous)
                except FuelPriceError as error:
                    results.append(error)
                clock.now += timedelta(minutes=15)
        return results

    return asyncio.run(scenario())


def test_prix_carburants_is_downloaded_then_confirmed_with_if_modified_since(settings):
    archive = _zip(
        ("PrixCarburants_instantane.xml", _fixture("prix_carburants_instantane_excerpt.xml"))
    )
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if "if-modified-since" in request.headers:
            return httpx.Response(304)
        return httpx.Response(
            200,
            content=archive,
            headers={"last-modified": "Sat, 10 Oct 2026 07:50:12 GMT"},
        )

    first, second = _run_france(settings, handler, SourceSnapshot(), SourceSnapshot())

    assert isinstance(first, SourceSnapshot) and isinstance(second, SourceSnapshot)
    assert len(first.stations) == 3
    assert requests[1].headers["if-modified-since"] == "Sat, 10 Oct 2026 07:50:12 GMT"
    # Unchanged is still a confirmation, and it is dated as one.
    assert second.stations == first.stations
    assert second.checked_at == START + timedelta(minutes=15)


@pytest.mark.parametrize(
    ("archive", "message"),
    [
        (b"not a zip", "not a ZIP"),
        (_zip(("a.xml", b"<pdv_liste/>"), ("b.xml", b"<pdv_liste/>")), "exactly one file"),
        (
            _zip(
                (
                    "x.xml",
                    b'<?xml version="1.0"?><!DOCTYPE lol [<!ENTITY a "a">]><pdv_liste/>',
                )
            ),
            "DTD",
        ),
        (_zip(("x.xml", b"<pdv_liste><pdv")), "well-formed"),
        (_zip(("x.xml", b"<pdv_liste></pdv_liste>")), "no stations"),
    ],
)
def test_prix_carburants_refuses_anything_that_is_not_the_feed(settings, archive, message):
    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=archive)

    (result,) = _run_france(settings, handler)
    assert isinstance(result, FuelPriceError)
    assert message in str(result)


def test_prix_carburants_refuses_an_oversized_feed(settings):
    small = settings.model_copy(update={"fuel_price_maximum_source_bytes": 256 * 1024})
    archive = _zip(("x.xml", b" " * (256 * 1024 * 16 + 1)))

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=archive)

    (result,) = _run_france(small, handler)
    assert isinstance(result, FuelPriceError)
    assert "size limit" in str(result)


class _StaticSource:
    source_id = UK_SOURCE_ID
    name = "Fuel Finder"
    attribution = "Synthetic attribution"
    currency = "GBP"
    report_error_url = "https://example.test/report"

    def __init__(self, stations: list[FuelStation], *, configured: bool = True):
        self._stations = stations
        self._configured = configured
        self.refreshes = 0

    @property
    def configured(self) -> bool:
        return self._configured

    async def refresh(self, snapshot: SourceSnapshot) -> SourceSnapshot:
        self.refreshes += 1
        return SourceSnapshot(
            stations={station.id: station for station in self._stations},
            checked_at=START,
        )


def _station(identifier: str, latitude: float, longitude: float, **kwargs) -> FuelStation:
    prices = kwargs.pop(
        "prices",
        {"e10": FuelPrice(140.0, reported_at=datetime(2026, 10, 9, 7, 0, tzinfo=UTC))},
    )
    return FuelStation(
        id=identifier,
        source=UK_SOURCE_ID,
        latitude=latitude,
        longitude=longitude,
        prices=prices,
        **kwargs,
    )


def _service(settings: Settings, stations: list[FuelStation], **overrides) -> FuelPriceService:
    source = _StaticSource(stations)
    service = FuelPriceService(
        settings.model_copy(update=overrides),
        sources=[source],
        clock=lambda: START + timedelta(minutes=5),
    )
    assert asyncio.run(service.refresh_once(source)) is True
    return service


def test_the_viewport_holds_only_priced_stations_inside_the_box(settings):
    service = _service(
        settings,
        [
            _station("uk:inside", 52.0, -1.5, name="Inside", brand="EXAMPLE"),
            _station("uk:outside", 53.0, -1.5),
            _station("uk:unpriced", 52.01, -1.51, prices={}),
            _station("uk:closed", 52.02, -1.52, closed=True),
        ],
    )

    result = service.viewport(west=-1.8, south=51.8, east=-1.2, north=52.2)

    assert [station["id"] for station in result["stations"]] == ["uk:inside", "uk:closed"]
    assert result["stations"][0] == {
        "id": "uk:inside",
        "source": UK_SOURCE_ID,
        "lat": 52.0,
        "lon": -1.5,
        "name": "Inside",
        "brand": "EXAMPLE",
        "prices": {"e10": {"minorPerLitre": 140.0, "reportedAt": "2026-10-09T07:00:00Z"}},
    }
    assert result["stations"][1]["closed"] is True
    assert result["sources"] == [
        {
            "id": UK_SOURCE_ID,
            "name": "Fuel Finder",
            "attribution": "Synthetic attribution",
            "currency": "GBP",
            "checkedAt": "2026-10-10T08:00:00Z",
            "reportErrorUrl": "https://example.test/report",
        }
    ]
    assert result["generatedAt"] == "2026-10-10T08:05:00Z"
    assert result["truncated"] is False


def test_a_crowded_viewport_keeps_the_stations_nearest_its_centre(settings):
    stations = [_station(f"uk:{index:02d}", 52.0 + index * 0.01, -1.5) for index in range(12)]
    service = _service(settings, stations, fuel_price_maximum_stations_per_response=10)

    result = service.viewport(west=-1.7, south=52.0, east=-1.3, north=52.11)

    kept = {station["id"] for station in result["stations"]}
    assert result["truncated"] is True
    assert len(kept) == 10
    # The two farthest from the box's centre (52.055) are the ones left out.
    assert "uk:00" not in kept and "uk:11" not in kept


def test_fuel_prices_are_unconfigured_and_unadvertised_by_default(client):
    response = client.get(
        "/api/v1/fuel/prices",
        params={"west": -1.8, "south": 51.8, "east": -1.2, "north": 52.2},
    )

    assert response.status_code == 503
    assert response.json() == {
        "code": "fuel_prices_unconfigured",
        "message": "Fuel prices are not configured on this relay.",
    }
    capabilities = client.get("/api/v1/compatibility").json()["capabilities"]
    assert FUEL_PRICES_CAPABILITY not in capabilities


def test_a_configured_relay_serves_the_viewport_and_advertises_prices(settings):
    service = _service(settings, [_station("uk:inside", 52.0, -1.5)])

    with TestClient(create_app(settings, fuel_price_service=service)) as test_client:
        response = test_client.get(
            "/api/v1/fuel/prices",
            params={"west": -1.8, "south": 51.8, "east": -1.2, "north": 52.2},
        )
        capabilities = test_client.get("/api/v1/compatibility").json()["capabilities"]

    assert response.status_code == 200
    assert [station["id"] for station in response.json()["stations"]] == ["uk:inside"]
    assert FUEL_PRICES_CAPABILITY in capabilities


@pytest.mark.parametrize(
    "params",
    [
        {"west": -1.2, "south": 51.8, "east": -1.8, "north": 52.2},
        {"west": -1.8, "south": 52.2, "east": -1.2, "north": 51.8},
        {"west": -2.0, "south": 51.8, "east": -1.0, "north": 52.2},
        {"west": -1.8, "south": 51.6, "east": -1.2, "north": 52.2},
    ],
)
def test_the_viewport_must_be_small_and_the_right_way_round(settings, params):
    service = _service(settings, [_station("uk:inside", 52.0, -1.5)])

    with TestClient(create_app(settings, fuel_price_service=service)) as test_client:
        response = test_client.get("/api/v1/fuel/prices", params=params)

    assert response.status_code == 400


def test_fuel_price_requests_are_rate_limited_per_address(settings):
    limited = settings.model_copy(update={"fuel_price_rate_limit_requests": 10})
    service = _service(limited, [_station("uk:inside", 52.0, -1.5)])
    params = {"west": -1.8, "south": 51.8, "east": -1.2, "north": 52.2}

    with TestClient(create_app(limited, fuel_price_service=service)) as test_client:
        statuses = [
            test_client.get("/api/v1/fuel/prices", params=params).status_code for _ in range(11)
        ]

    assert statuses[:10] == [200] * 10
    assert statuses[10] == 429


def test_the_background_refresh_runs_only_configured_sources_and_stops_cleanly(settings):
    configured = _StaticSource([_station("uk:inside", 52.0, -1.5)])
    unconfigured = _StaticSource([], configured=False)
    unconfigured.source_id = FR_SOURCE_ID
    parked = asyncio.Event()

    async def sleep(_: float) -> None:
        parked.set()
        await asyncio.Event().wait()

    async def scenario() -> None:
        service = FuelPriceService(settings, sources=[configured, unconfigured], sleep=sleep)
        service.start()
        await asyncio.wait_for(parked.wait(), timeout=5)
        await service.close()

    asyncio.run(scenario())

    assert configured.refreshes == 1
    assert unconfigured.refreshes == 0


def test_an_unexpected_source_failure_does_not_end_the_refresh_loop(settings):
    class _Broken(_StaticSource):
        async def refresh(self, snapshot: SourceSnapshot) -> SourceSnapshot:
            self.refreshes += 1
            raise KeyError("an unanticipated shape")

    broken = _Broken([])
    sleeps: list[float] = []
    second_round = asyncio.Event()

    async def sleep(seconds: float) -> None:
        sleeps.append(seconds)
        if len(sleeps) >= 2:
            second_round.set()
            await asyncio.Event().wait()

    async def scenario() -> None:
        service = FuelPriceService(settings, sources=[broken], sleep=sleep)
        service.start()
        await asyncio.wait_for(second_round.wait(), timeout=5)
        await service.close()

    asyncio.run(scenario())

    assert broken.refreshes == 2
    # Retried on the shorter failure interval, not the normal cadence.
    # A failed pass retries no later than the next scheduled check.
    assert sleeps == [240, 240]


def test_a_relay_with_no_source_starts_no_background_task(settings):
    async def scenario() -> FuelPriceService:
        service = FuelPriceService(settings)
        service.start()
        assert service._task is None
        await service.close()
        return service

    asyncio.run(scenario())


def test_the_viewport_json_is_compact(settings):
    service = _service(settings, [_station("uk:inside", 52.0, -1.5)])
    body = json.dumps(service.viewport(west=-1.8, south=51.8, east=-1.2, north=52.2))
    # One priced station is a few hundred bytes, so 600 stay well under 256 KB.
    assert len(body) < 600
