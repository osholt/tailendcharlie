"""Fuel prices, fetched from official sources and served per viewport (#951).

The decision record is `docs/fuel-and-charging-data-decision.md`. In short:

- Phones never call a government API. The relay fetches each source on its own
  cadence, holds the result in memory, and answers a bounded bounding box.
- The UK source is the statutory Fuel Finder API, which needs registered OAuth
  client credentials. The French source is the prix-carburants open feed,
  which needs none and is off until enabled.
- Nothing here is a bulk export: a response is a reduced record (position,
  name, brand, the grades the app uses and their timestamps) for at most a few
  hundred stations in a small box.
- A source's timestamps are passed through unaltered. The only time the relay
  adds is when it last confirmed the source, so a rider can tell how old the
  relay's copy is, separately from when the forecourt set its price.

The in-memory snapshot is bounded (stations per source, response sizes) so it
fits the small relay host.
"""

from __future__ import annotations

import asyncio
import io
import logging
import math
import zipfile
from collections.abc import Awaitable, Callable, Iterable, Iterator, Mapping
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime, timedelta
from email.utils import parsedate_to_datetime
from typing import Protocol
from xml.etree import ElementTree

import httpx

from .config import Settings

logger = logging.getLogger(__name__)

FUEL_PRICES_CAPABILITY = "fuel-prices-v1"

# The grades the app offers as a preference. Every source maps onto these and
# drops the rest: a grade nobody can choose is weight in every response.
APP_GRADES = ("e10", "e5", "diesel", "dieselPremium")

UK_SOURCE_ID = "uk-fuel-finder"
FR_SOURCE_ID = "fr-prix-carburants"

UK_ATTRIBUTION = (
    "Contains public sector information licensed under the Open Government "
    "Licence v3.0. Prices from Fuel Finder."
)
UK_REPORT_ERROR_URL = (
    "https://www.gov.uk/guidance/report-an-error-in-fuel-prices-or-forecourt-details"
)
FR_ATTRIBUTION = "Prix des carburants en France, Licence Ouverte / Etalab 2.0."
FR_REPORT_ERROR_URL = "https://www.prix-carburants.gouv.fr/"

_UK_TOKEN_PATH = "/api/v1/oauth/generate_access_token"  # noqa: S105 - a URL path
_UK_STATIONS_PATH = "/api/v1/pfs"
_UK_PRICES_PATH = "/api/v1/pfs/fuel-prices"

# Fuel Finder grade codes as documented (`E10`, `E5`, `B7_Standard`,
# `B7_Premium`) and as abbreviated in its CSV (`B7S`, `B7P`). Matched without
# case. `B10` and `HVO` are not grades a rider can choose.
_UK_GRADES = {
    "E10": "e10",
    "E5": "e5",
    "B7_STANDARD": "diesel",
    "B7S": "diesel",
    "B7_PREMIUM": "dieselPremium",
    "B7P": "dieselPremium",
}
# France: super unleaded is SP98. SP95 is a different grade from both E10 and
# SP98, and presenting it as either would show a price for a fuel the rider did
# not choose, so it is dropped.
_FR_GRADES = {"E10": "e10", "SP98": "e5", "GAZOLE": "diesel"}

# Plausible pump prices in minor units per litre. Anything outside is a data
# fault (a price keyed in pounds, a placeholder zero) and is dropped rather than
# corrected: guessing which way it was wrong could show a rider a wrong price.
_MINIMUM_MINOR_PER_LITRE = 50.0
_MAXIMUM_MINOR_PER_LITRE = 400.0

# The UK scheme gives a forecourt 30 minutes to report a change and the API five
# more to publish it, so a change can surface with an effective time up to 35
# minutes before the moment it appears. Asking for changes since the previous
# check minus this overlap means none is missed.
_UK_INCREMENTAL_OVERLAP = timedelta(minutes=45)
_UK_FULL_PRICE_INTERVAL = timedelta(hours=24)
_UK_STATION_INTERVAL = timedelta(hours=6)
_UK_MAXIMUM_BATCHES = 80

_GRID_DEGREES = 0.25


class FuelPriceError(RuntimeError):
    """A source could not be read. The previous snapshot stays in place."""


@dataclass(frozen=True, slots=True)
class FuelPrice:
    """One grade's price at one station, with the source's own timestamps."""

    minor_per_litre: float
    reported_at: datetime | None
    effective_at: datetime | None = None

    def as_json(self) -> dict[str, object]:
        result: dict[str, object] = {"minorPerLitre": self.minor_per_litre}
        if self.reported_at is not None:
            result["reportedAt"] = _iso(self.reported_at)
        if self.effective_at is not None:
            result["effectiveAt"] = _iso(self.effective_at)
        return result


@dataclass(frozen=True, slots=True)
class FuelStation:
    id: str
    source: str
    latitude: float
    longitude: float
    name: str | None = None
    brand: str | None = None
    closed: bool = False
    prices: Mapping[str, FuelPrice] = field(default_factory=dict)

    def as_json(self) -> dict[str, object]:
        result: dict[str, object] = {
            "id": self.id,
            "source": self.source,
            "lat": round(self.latitude, 6),
            "lon": round(self.longitude, 6),
            "prices": {grade: price.as_json() for grade, price in sorted(self.prices.items())},
        }
        if self.name:
            result["name"] = self.name
        if self.brand:
            result["brand"] = self.brand
        if self.closed:
            result["closed"] = True
        return result


@dataclass(slots=True)
class SourceSnapshot:
    """Everything one source has told the relay, and when it last confirmed it."""

    stations: dict[str, FuelStation] = field(default_factory=dict)
    checked_at: datetime | None = None


class FuelPriceSource(Protocol):
    source_id: str
    name: str
    attribution: str
    currency: str
    report_error_url: str

    @property
    def configured(self) -> bool: ...

    async def refresh(self, snapshot: SourceSnapshot) -> SourceSnapshot: ...


Sleep = Callable[[float], Awaitable[None]]
Clock = Callable[[], datetime]


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _plausible_price(value: object, *, scale: float = 1.0) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        return None
    try:
        price = float(value) * scale
    except ValueError:
        return None
    if not math.isfinite(price):
        return None
    if not _MINIMUM_MINOR_PER_LITRE <= price <= _MAXIMUM_MINOR_PER_LITRE:
        return None
    return round(price, 1)


def _coordinate(value: object, minimum: float, maximum: float) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        return None
    try:
        number = float(value)
    except ValueError:
        return None
    if not math.isfinite(number) or not minimum <= number <= maximum:
        return None
    return number


def _text(value: object, maximum: int = 80) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = " ".join(value.split())
    if not cleaned:
        return None
    return cleaned[:maximum]


def _utc_timestamp(value: object) -> datetime | None:
    """An RFC 3339 / ISO 8601 UTC timestamp as Fuel Finder documents them."""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _records(body: object) -> list[Mapping[str, object]]:
    """The list of records in a Fuel Finder response.

    The two open-source clients that document the API disagree on whether the
    body is a bare list or wrapped in one or two `data` envelopes, so every
    shape is accepted. Anything else is an error rather than an empty page: an
    unexpected shape read as "no more batches" would silently truncate the set.
    """
    current = body
    for _ in range(3):
        if isinstance(current, list):
            return [record for record in current if isinstance(record, Mapping)]
        if isinstance(current, Mapping) and "data" in current:
            current = current["data"]
            continue
        break
    raise FuelPriceError("Fuel Finder returned an unexpected response shape")


def parse_uk_stations(records: Iterable[Mapping[str, object]]) -> dict[str, FuelStation]:
    """Forecourt records keyed by node id, without prices.

    A forecourt without a usable position is dropped: the response is a map
    layer, and a station with no place on it cannot be shown or navigated to.
    """
    stations: dict[str, FuelStation] = {}
    for record in records:
        node_id = _text(record.get("node_id"), 128)
        location = record.get("location")
        if node_id is None or not isinstance(location, Mapping):
            continue
        latitude = _coordinate(location.get("latitude"), -90, 90)
        longitude = _coordinate(location.get("longitude"), -180, 180)
        if latitude is None or longitude is None:
            continue
        stations[node_id] = FuelStation(
            id=f"uk:{node_id}",
            source=UK_SOURCE_ID,
            latitude=latitude,
            longitude=longitude,
            name=_text(record.get("trading_name")),
            brand=_text(record.get("brand_name")),
            closed=record.get("temporary_closure") is True
            or record.get("permanent_closure") is True,
        )
    return stations


def parse_uk_prices(
    records: Iterable[Mapping[str, object]],
) -> Iterator[tuple[str, dict[str, FuelPrice]]]:
    """Per-forecourt prices for the app's grades, keyed by node id."""
    for record in records:
        node_id = _text(record.get("node_id"), 128)
        entries = record.get("fuel_prices")
        if node_id is None or not isinstance(entries, list):
            continue
        prices: dict[str, FuelPrice] = {}
        for entry in entries:
            if not isinstance(entry, Mapping):
                continue
            grade_code = entry.get("fuel_type")
            if not isinstance(grade_code, str):
                continue
            grade = _UK_GRADES.get(grade_code.strip().upper())
            price = _plausible_price(entry.get("price"))
            if grade is None or price is None:
                continue
            prices[grade] = FuelPrice(
                minor_per_litre=price,
                reported_at=_utc_timestamp(entry.get("price_last_updated")),
                effective_at=_utc_timestamp(entry.get("price_change_effective_timestamp")),
            )
        yield node_id, prices


class FuelFinderSource:
    """The statutory UK Fuel Finder API (SI 2025/1356).

    Requests are strictly serial and paced: the scheme allows one concurrent
    request per client and returns 429 beyond its per-minute limit.
    """

    source_id = UK_SOURCE_ID
    name = "Fuel Finder"
    attribution = UK_ATTRIBUTION
    currency = "GBP"
    report_error_url = UK_REPORT_ERROR_URL

    def __init__(
        self,
        settings: Settings,
        *,
        client: httpx.AsyncClient,
        clock: Clock = _now,
        sleep: Sleep = asyncio.sleep,
    ):
        self._client_id = settings.fuel_finder_client_id
        secret = settings.fuel_finder_client_secret
        self._client_secret = secret.get_secret_value() if secret is not None else None
        self._base_url = settings.fuel_finder_base_url.rstrip("/")
        self._interval = settings.fuel_price_request_interval_seconds
        self._maximum_response_bytes = settings.fuel_price_maximum_source_bytes
        self._maximum_stations = settings.fuel_price_maximum_stations_per_source
        self._client = client
        self._clock = clock
        self._sleep = sleep
        self._token: str | None = None
        self._token_expires_at: datetime | None = None
        self._last_request_at: datetime | None = None
        self._stations: dict[str, FuelStation] = {}
        self._stations_loaded_at: datetime | None = None
        self._full_prices_at: datetime | None = None
        self._prices_since: datetime | None = None

    @property
    def configured(self) -> bool:
        return bool(self._client_id) and bool(self._client_secret)

    async def refresh(self, snapshot: SourceSnapshot) -> SourceSnapshot:
        started = self._clock()
        if (
            self._stations_loaded_at is None
            or started - self._stations_loaded_at >= _UK_STATION_INTERVAL
        ):
            records = await self._all_batches(_UK_STATIONS_PATH)
            stations = parse_uk_stations(records)
            if not stations:
                raise FuelPriceError("Fuel Finder returned no forecourts with a position")
            if len(stations) > self._maximum_stations:
                raise FuelPriceError("Fuel Finder returned more forecourts than the relay holds")
            self._stations = stations
            self._stations_loaded_at = started
        full = (
            self._full_prices_at is None
            or self._prices_since is None
            or started - self._full_prices_at >= _UK_FULL_PRICE_INTERVAL
        )
        since = None if full else self._prices_since - _UK_INCREMENTAL_OVERLAP
        records = await self._all_batches(_UK_PRICES_PATH, since=since)
        previous = (
            {} if full else {key: station.prices for key, station in snapshot.stations.items()}
        )
        updated: dict[str, FuelStation] = {}
        prices_by_node: dict[str, dict[str, FuelPrice]] = {}
        for node_id, prices in parse_uk_prices(records):
            prices_by_node.setdefault(node_id, {}).update(prices)
        for node_id, station in self._stations.items():
            key = station.id
            merged = dict(previous.get(key, {}))
            merged.update(prices_by_node.get(node_id, {}))
            updated[key] = replace(station, prices=merged)
        if full:
            self._full_prices_at = started
        self._prices_since = started
        return SourceSnapshot(stations=updated, checked_at=self._clock())

    async def _all_batches(
        self,
        path: str,
        *,
        since: datetime | None = None,
    ) -> list[Mapping[str, object]]:
        records: list[Mapping[str, object]] = []
        for batch in range(1, _UK_MAXIMUM_BATCHES + 1):
            params = {"batch-number": str(batch)}
            if since is not None:
                params["effective-start-timestamp"] = since.astimezone(UTC).strftime(
                    "%Y-%m-%d %H:%M:%S"
                )
            response = await self._get(path, params)
            if response is None:
                return records
            page = _records(response)
            if not page:
                return records
            records.extend(page)
            if len(records) > self._maximum_stations * 2:
                raise FuelPriceError("Fuel Finder returned more records than the relay holds")
        raise FuelPriceError("Fuel Finder kept paging past the relay's batch limit")

    async def _get(self, path: str, params: Mapping[str, str]) -> object | None:
        token = await self._access_token()
        await self._pace()
        try:
            response = await self._client.get(
                f"{self._base_url}{path}",
                params=params,
                headers={"accept": "application/json", "authorization": f"Bearer {token}"},
            )
        except httpx.HTTPError as error:
            raise FuelPriceError("Fuel Finder could not be reached") from error
        if response.status_code == 404:
            # The documented clients read a 404 past the last batch as the end.
            return None
        if response.status_code == 401:
            self._token = None
            raise FuelPriceError("Fuel Finder rejected the relay's access token")
        if response.status_code == 429:
            raise FuelPriceError("Fuel Finder rate limit reached")
        if response.status_code != 200:
            raise FuelPriceError(f"Fuel Finder answered {response.status_code}")
        if len(response.content) > self._maximum_response_bytes:
            raise FuelPriceError("Fuel Finder response exceeded the relay's size limit")
        try:
            return response.json()
        except ValueError as error:
            raise FuelPriceError("Fuel Finder returned malformed JSON") from error

    async def _access_token(self) -> str:
        now = self._clock()
        if (
            self._token is not None
            and self._token_expires_at is not None
            and now < self._token_expires_at
        ):
            return self._token
        if not self.configured:
            raise FuelPriceError("Fuel Finder credentials are not configured")
        await self._pace()
        try:
            response = await self._client.post(
                f"{self._base_url}{_UK_TOKEN_PATH}",
                data={
                    "grant_type": "client_credentials",
                    "client_id": self._client_id,
                    "client_secret": self._client_secret or "",
                    "scope": "fuelfinder.read",
                },
                headers={"accept": "application/json"},
            )
        except httpx.HTTPError as error:
            raise FuelPriceError("Fuel Finder token endpoint could not be reached") from error
        if response.status_code != 200:
            # The status alone: a token endpoint's error body can echo the
            # request, and the request holds the client secret.
            raise FuelPriceError(f"Fuel Finder token request answered {response.status_code}")
        try:
            body = response.json()
        except ValueError as error:
            raise FuelPriceError("Fuel Finder token response was malformed") from error
        data = body.get("data") if isinstance(body, Mapping) and "data" in body else body
        if not isinstance(data, Mapping):
            raise FuelPriceError("Fuel Finder token response was malformed")
        token = data.get("access_token")
        expires_in = data.get("expires_in")
        if not isinstance(token, str) or not token:
            raise FuelPriceError("Fuel Finder token response held no token")
        lifetime = expires_in if isinstance(expires_in, int) and expires_in > 0 else 3600
        self._token = token
        # Renew a minute early so a long paged fetch never sends an expired one.
        self._token_expires_at = now + timedelta(seconds=max(60, lifetime - 60))
        return token

    async def _pace(self) -> None:
        now = self._clock()
        if self._last_request_at is not None:
            wait = self._interval - (now - self._last_request_at).total_seconds()
            if wait > 0:
                await self._sleep(wait)
        self._last_request_at = self._clock()


def _last_sunday(year: int, month: int) -> datetime:
    day = datetime(year, month + 1, 1, tzinfo=UTC) - timedelta(days=1)
    return day - timedelta(days=(day.weekday() - 6) % 7)


def paris_local_to_utc(local: datetime) -> datetime:
    """French local time to UTC under the EU summer-time rule.

    Summer time runs from 01:00 UTC on the last Sunday of March to 01:00 UTC on
    the last Sunday of October (Directive 2000/84/EC). Computed here rather than
    read from a time-zone database so the result does not depend on what the
    host image happens to ship.
    """
    naive = local.replace(tzinfo=None)
    year = naive.year
    summer_start = _last_sunday(year, 3).replace(hour=1, tzinfo=None)
    summer_end = _last_sunday(year, 10).replace(hour=1, tzinfo=None)
    as_winter = naive - timedelta(hours=1)
    as_summer = naive - timedelta(hours=2)
    if summer_start <= as_summer < summer_end:
        return as_summer.replace(tzinfo=UTC)
    return as_winter.replace(tzinfo=UTC)


def _http_date(value: str | None) -> str | None:
    """A Last-Modified value worth echoing back, or None if it is not a date."""
    if not value:
        return None
    try:
        parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    return value


def _paris_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace(" ", "T"))
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        return parsed.astimezone(UTC)
    return paris_local_to_utc(parsed)


def parse_prix_carburants(xml: bytes, *, maximum_stations: int) -> dict[str, FuelStation]:
    """The instantaneous prix-carburants XML, as stations with prices.

    Positions are PTV_GEODECIMAL: degrees multiplied by 100,000. The feed has no
    station names or brands; the app names a French station from its own map
    data where it can.
    """
    head = xml[:4096].lower()
    if b"<!doctype" in head or b"<!entity" in head:
        # The published feed has neither. One that does is not the feed, and
        # entity declarations are how XML expansion attacks begin.
        raise FuelPriceError("prix-carburants feed declared a DTD")
    stations: dict[str, FuelStation] = {}
    try:
        # The feed is size-capped before it gets here and carries no DTD (checked
        # above), so the standard parser's entity handling is not reachable.
        for _, element in ElementTree.iterparse(io.BytesIO(xml), events=("end",)):  # noqa: S314
            if element.tag != "pdv":
                continue
            station = _prix_carburants_station(element)
            element.clear()
            if station is None:
                continue
            stations[station.id] = station
            if len(stations) > maximum_stations:
                raise FuelPriceError("prix-carburants feed held more stations than the relay holds")
    except ElementTree.ParseError as error:
        raise FuelPriceError("prix-carburants feed was not well-formed XML") from error
    return stations


def _prix_carburants_station(element: ElementTree.Element) -> FuelStation | None:
    station_id = _text(element.get("id"), 32)
    latitude = _coordinate(element.get("latitude"), -9_000_000, 9_000_000)
    longitude = _coordinate(element.get("longitude"), -18_000_000, 18_000_000)
    if station_id is None or latitude is None or longitude is None:
        return None
    latitude /= 100_000
    longitude /= 100_000
    if latitude == 0 and longitude == 0:
        return None
    prices: dict[str, FuelPrice] = {}
    for price in element.findall("prix"):
        name = price.get("nom")
        grade = _FR_GRADES.get(name.strip().upper()) if name else None
        value = _plausible_price(price.get("valeur"), scale=100.0)
        if grade is None or value is None:
            continue
        prices[grade] = FuelPrice(
            minor_per_litre=value,
            reported_at=_paris_timestamp(price.get("maj")),
        )
    return FuelStation(
        id=f"fr:{station_id}",
        source=FR_SOURCE_ID,
        latitude=latitude,
        longitude=longitude,
        prices=prices,
    )


class PrixCarburantsSource:
    """France's open instantaneous fuel price feed (Etalab 2.0, no credentials)."""

    source_id = FR_SOURCE_ID
    name = "prix-carburants.gouv.fr"
    attribution = FR_ATTRIBUTION
    currency = "EUR"
    report_error_url = FR_REPORT_ERROR_URL

    def __init__(
        self,
        settings: Settings,
        *,
        client: httpx.AsyncClient,
        clock: Clock = _now,
    ):
        self._enabled = settings.fuel_prices_france_enabled
        self._url = settings.fuel_prices_france_url
        self._maximum_archive_bytes = settings.fuel_price_maximum_source_bytes
        self._maximum_xml_bytes = settings.fuel_price_maximum_source_bytes * 16
        self._maximum_stations = settings.fuel_price_maximum_stations_per_source
        self._client = client
        self._clock = clock
        self._last_modified: str | None = None

    @property
    def configured(self) -> bool:
        return self._enabled

    async def refresh(self, snapshot: SourceSnapshot) -> SourceSnapshot:
        headers = {"accept": "application/zip"}
        if self._last_modified is not None and snapshot.stations:
            headers["if-modified-since"] = self._last_modified
        try:
            response = await self._client.get(self._url, headers=headers)
        except httpx.HTTPError as error:
            raise FuelPriceError("prix-carburants could not be reached") from error
        if response.status_code == 304:
            # Unchanged since the last download: still a confirmation.
            return SourceSnapshot(stations=snapshot.stations, checked_at=self._clock())
        if response.status_code != 200:
            raise FuelPriceError(f"prix-carburants answered {response.status_code}")
        if len(response.content) > self._maximum_archive_bytes:
            raise FuelPriceError("prix-carburants archive exceeded the relay's size limit")
        xml = self._extract(response.content)
        stations = parse_prix_carburants(xml, maximum_stations=self._maximum_stations)
        if not stations:
            raise FuelPriceError("prix-carburants feed held no stations")
        self._last_modified = _http_date(response.headers.get("last-modified"))
        return SourceSnapshot(stations=stations, checked_at=self._clock())

    def _extract(self, archive: bytes) -> bytes:
        try:
            with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                members = [info for info in bundle.infolist() if not info.is_dir()]
                if len(members) != 1:
                    raise FuelPriceError("prix-carburants archive did not hold exactly one file")
                member = members[0]
                if member.file_size > self._maximum_xml_bytes:
                    raise FuelPriceError("prix-carburants feed exceeded the relay's size limit")
                with bundle.open(member) as handle:
                    data = handle.read(self._maximum_xml_bytes + 1)
        except zipfile.BadZipFile as error:
            raise FuelPriceError("prix-carburants archive was not a ZIP file") from error
        if len(data) > self._maximum_xml_bytes:
            raise FuelPriceError("prix-carburants feed exceeded the relay's size limit")
        return data


class _Grid:
    """Stations bucketed by a quarter-degree cell, so a viewport reads a few cells."""

    def __init__(self, stations: Iterable[FuelStation]):
        self._cells: dict[tuple[int, int], list[FuelStation]] = {}
        for station in stations:
            self._cells.setdefault(_cell(station.latitude, station.longitude), []).append(station)

    def within(self, west: float, south: float, east: float, north: float) -> Iterator[FuelStation]:
        south_cell, west_cell = _cell(south, west)
        north_cell, east_cell = _cell(north, east)
        for row in range(south_cell, north_cell + 1):
            for column in range(west_cell, east_cell + 1):
                for station in self._cells.get((row, column), ()):
                    if south <= station.latitude <= north and west <= station.longitude <= east:
                        yield station


def _cell(latitude: float, longitude: float) -> tuple[int, int]:
    return math.floor(latitude / _GRID_DEGREES), math.floor(longitude / _GRID_DEGREES)


def validate_fuel_viewport(
    west: float,
    south: float,
    east: float,
    north: float,
    *,
    maximum_latitude_span: float,
    maximum_longitude_span: float,
) -> None:
    if west >= east or south >= north:
        raise ValueError("Fuel price bounds must have west < east and south < north")
    if north - south > maximum_latitude_span or east - west > maximum_longitude_span:
        raise ValueError(
            f"Fuel price bounds may span at most {maximum_latitude_span}° of latitude "
            f"and {maximum_longitude_span}° of longitude"
        )


class FuelPriceService:
    """Holds every configured source's snapshot and refreshes it in the background."""

    def __init__(
        self,
        settings: Settings,
        *,
        sources: list[FuelPriceSource] | None = None,
        client: httpx.AsyncClient | None = None,
        clock: Clock = _now,
        sleep: Sleep = asyncio.sleep,
    ):
        self._client: httpx.AsyncClient | None = None
        if sources is None:
            self._client = client or httpx.AsyncClient(
                timeout=httpx.Timeout(settings.fuel_price_timeout_seconds),
                follow_redirects=False,
            )
            sources = [
                FuelFinderSource(settings, client=self._client, clock=clock, sleep=sleep),
                PrixCarburantsSource(settings, client=self._client, clock=clock),
            ]
        self._owns_client = client is None and self._client is not None
        self._sources = sources
        self._refresh_seconds = settings.fuel_price_refresh_seconds
        self._retry_seconds = min(300, settings.fuel_price_refresh_seconds)
        self._maximum_stations = settings.fuel_price_maximum_stations_per_response
        self._clock = clock
        self._sleep = sleep
        self._snapshots: dict[str, SourceSnapshot] = {
            source.source_id: SourceSnapshot() for source in self._sources
        }
        self._grids: dict[str, _Grid] = {}
        self._task: asyncio.Task[None] | None = None

    @property
    def configured(self) -> bool:
        return any(source.configured for source in self._sources)

    @property
    def _configured_sources(self) -> list[FuelPriceSource]:
        return [source for source in self._sources if source.configured]

    async def refresh_once(self, source: FuelPriceSource) -> bool:
        """Refresh one source. On failure the previous snapshot is kept as it was.

        Keeping it is safe because every response says when the relay last
        confirmed the source, and the app stops presenting a price as current
        once that confirmation is old.
        """
        previous = self._snapshots.get(source.source_id, SourceSnapshot())
        try:
            snapshot = await source.refresh(previous)
        except FuelPriceError as error:
            logger.warning("Fuel price source %s not refreshed: %s", source.source_id, error)
            return False
        self._snapshots[source.source_id] = snapshot
        self._grids[source.source_id] = _Grid(snapshot.stations.values())
        return True

    def start(self) -> None:
        if self._task is not None or not self.configured:
            return
        self._task = asyncio.create_task(self._run(), name="fuel-price-refresh")

    async def _run(self) -> None:
        while True:
            succeeded = True
            for source in self._configured_sources:
                succeeded = await self.refresh_once(source) and succeeded
            await self._sleep(self._refresh_seconds if succeeded else self._retry_seconds)

    async def close(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        if self._owns_client and self._client is not None:
            await self._client.aclose()

    def viewport(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]:
        centre_latitude = (south + north) / 2
        centre_longitude = (west + east) / 2
        longitude_scale = math.cos(math.radians(centre_latitude))
        found: list[tuple[float, FuelStation]] = []
        sources: list[dict[str, object]] = []
        for source in self._configured_sources:
            snapshot = self._snapshots.get(source.source_id, SourceSnapshot())
            sources.append(
                {
                    "id": source.source_id,
                    "name": source.name,
                    "attribution": source.attribution,
                    "currency": source.currency,
                    "checkedAt": _iso(snapshot.checked_at) if snapshot.checked_at else None,
                    "reportErrorUrl": source.report_error_url,
                }
            )
            grid = self._grids.get(source.source_id)
            if grid is None:
                continue
            for station in grid.within(west, south, east, north):
                if not station.prices:
                    continue
                distance = math.hypot(
                    station.latitude - centre_latitude,
                    (station.longitude - centre_longitude) * longitude_scale,
                )
                found.append((distance, station))
        # Geometry is the only selection rule when a box is too full: the
        # nearest stations to its centre, whatever their brand.
        found.sort(key=lambda item: (item[0], item[1].id))
        truncated = len(found) > self._maximum_stations
        return {
            "schemaVersion": 1,
            "generatedAt": _iso(self._clock()),
            "sources": sources,
            "stations": [station.as_json() for _, station in found[: self._maximum_stations]],
            "truncated": truncated,
        }
