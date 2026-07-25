from __future__ import annotations

import asyncio
import math
from collections.abc import Callable, Mapping
from datetime import UTC, datetime, timedelta
from typing import Protocol

import httpx

from .config import Settings

_TOMTOM_INCIDENT_URL = "https://api.tomtom.com/maps/orbis/traffic/incidents/details"
_TOMTOM_ATTRIBUTES = (
    "incidents(type,geometry(type,coordinates),properties("
    "id,iconCategory,magnitudeOfDelay,events(description,code,iconCategory),"
    "startTime,endTime,from,to,lengthInMeters,delayInSeconds,roadNumbers,"
    "timeValidity,probabilityOfOccurrence,numberOfReports,lastReportTime))"
)
_CATEGORY_NAMES = {
    0: "unknown",
    1: "accident",
    2: "fog",
    3: "dangerousConditions",
    4: "rain",
    5: "ice",
    6: "jam",
    7: "laneClosed",
    8: "roadClosed",
    9: "roadWorks",
    10: "wind",
    11: "flooding",
    14: "brokenDownVehicle",
}
_MAGNITUDE_NAMES = {
    0: "unknown",
    1: "minor",
    2: "moderate",
    3: "major",
    4: "undefined",
}


class TrafficProviderError(RuntimeError):
    def __init__(self, message: str, *, retry_after: int | None = None):
        super().__init__(message)
        self.retry_after = retry_after


class TrafficIncidentProvider(Protocol):
    @property
    def configured(self) -> bool: ...

    async def incidents(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]: ...

    async def close(self) -> None: ...


class TomTomOrbisTrafficProvider:
    def __init__(
        self,
        settings: Settings,
        *,
        client: httpx.AsyncClient | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ):
        self._api_key = settings.tomtom_traffic_api_key
        self._timeout_seconds = settings.traffic_provider_timeout_seconds
        self._cache_seconds = settings.traffic_incident_cache_seconds
        self._maximum_response_bytes = settings.traffic_incident_maximum_response_bytes
        self._clock = clock
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(self._timeout_seconds),
            http2=True,
            follow_redirects=False,
        )
        self._owns_client = client is None
        self._lock = asyncio.Lock()
        self._cache: dict[
            tuple[float, float, float, float],
            tuple[datetime, dict[str, object]],
        ] = {}

    @property
    def configured(self) -> bool:
        return self._api_key is not None

    async def incidents(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]:
        if self._api_key is None:
            raise TrafficProviderError("Traffic incident provider is not configured")
        bounds = _quantized_bounds(west, south, east, north)
        now = self._clock()
        cached = self._cache.get(bounds)
        if cached is not None and now - cached[0] < timedelta(seconds=self._cache_seconds):
            return cached[1]

        async with self._lock:
            now = self._clock()
            cached = self._cache.get(bounds)
            if cached is not None and now - cached[0] < timedelta(seconds=self._cache_seconds):
                return cached[1]
            result = await self._fetch(bounds, now)
            self._cache[bounds] = (now, result)
            if len(self._cache) > 128:
                oldest = min(self._cache, key=lambda key: self._cache[key][0])
                self._cache.pop(oldest, None)
            return result

    async def _fetch(
        self,
        bounds: tuple[float, float, float, float],
        fetched_at: datetime,
    ) -> dict[str, object]:
        try:
            response = await self._client.get(
                _TOMTOM_INCIDENT_URL,
                params={
                    "apiVersion": "2",
                    "bbox": ",".join(_format_coordinate(value) for value in bounds),
                    "timeValidity": "present",
                    "language": "en-GB",
                },
                headers={
                    "TomTom-Api-Key": self._api_key.get_secret_value(),
                    "Attributes": _TOMTOM_ATTRIBUTES,
                    "Accept": "application/json",
                },
            )
        except httpx.HTTPError as error:
            raise TrafficProviderError("Traffic incident provider is unavailable") from error

        if response.status_code == 429:
            raise TrafficProviderError(
                "Traffic incident provider rate limit reached",
                retry_after=_retry_after_seconds(response.headers),
            )
        if response.status_code != 200:
            raise TrafficProviderError("Traffic incident provider request failed")
        if len(response.content) > self._maximum_response_bytes:
            raise TrafficProviderError("Traffic incident response exceeded the safe size limit")
        try:
            payload = response.json()
        except ValueError as error:
            raise TrafficProviderError("Traffic incident provider returned invalid data") from error
        raw_incidents = payload.get("incidents") if isinstance(payload, Mapping) else None
        if not isinstance(raw_incidents, list):
            raise TrafficProviderError("Traffic incident provider returned invalid data")

        incidents = [
            incident
            for item in raw_incidents[:500]
            if (incident := _normalise_incident(item, fetched_at)) is not None
        ]
        return {
            "provider": "tomtom-orbis",
            "fetchedAt": fetched_at.isoformat().replace("+00:00", "Z"),
            "trafficModelId": response.headers.get("TrafficModelID"),
            "incidents": incidents,
        }

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


def validate_uk_incident_bounds(
    west: float,
    south: float,
    east: float,
    north: float,
) -> None:
    if west >= east or south >= north:
        raise ValueError("A bounded traffic viewport is required")
    if west < -11.5 or east > 3.0 or south < 49.0 or north > 61.5:
        raise ValueError("Traffic incidents are currently available only for UK routes")
    latitude_km = (north - south) * 111.32
    longitude_km = (east - west) * 111.32 * math.cos(math.radians((south + north) / 2))
    if latitude_km * longitude_km > 9_500:
        raise ValueError("Traffic viewport exceeds the provider area limit")


def _normalise_incident(
    raw: object,
    fetched_at: datetime,
) -> dict[str, object] | None:
    if not isinstance(raw, Mapping):
        return None
    properties = raw.get("properties")
    geometry = raw.get("geometry")
    if not isinstance(properties, Mapping) or not isinstance(geometry, Mapping):
        return None
    incident_id = properties.get("id")
    if not isinstance(incident_id, str) or not incident_id or len(incident_id) > 200:
        return None
    points = _normalise_geometry(geometry)
    if not points:
        return None

    category = _category_name(properties.get("iconCategory"))
    magnitude = _magnitude_name(properties.get("magnitudeOfDelay"))
    observed_at = (
        _parse_time(properties.get("lastReportTime"))
        or _parse_time(properties.get("startTime"))
        or fetched_at
    )
    provider_end = _parse_time(properties.get("endTime"))
    refresh_expiry = fetched_at + timedelta(minutes=15)
    expires_at = (
        min(provider_end, refresh_expiry)
        if provider_end is not None and provider_end > fetched_at
        else refresh_expiry
    )
    events = properties.get("events")
    event_description = None
    if isinstance(events, list):
        for event in events:
            if isinstance(event, Mapping) and isinstance(event.get("description"), str):
                event_description = event["description"].strip()
                if event_description:
                    break

    return {
        "id": incident_id,
        "type": _hazard_type(category),
        "severity": _hazard_severity(category, magnitude),
        "category": category,
        "magnitude": magnitude,
        "description": _incident_description(properties, event_description),
        "direction": {
            "from": _short_string(properties.get("from"), 100),
            "to": _short_string(properties.get("to"), 100),
        },
        "geometry": points,
        "observedAt": observed_at.isoformat().replace("+00:00", "Z"),
        "expiresAt": expires_at.isoformat().replace("+00:00", "Z"),
        "delaySeconds": _optional_nonnegative_int(properties.get("delayInSeconds")),
        "roadNumbers": _short_strings(properties.get("roadNumbers"), maximum=8),
        "probability": _short_string(properties.get("probabilityOfOccurrence"), 40),
        "reportCount": _optional_nonnegative_int(properties.get("numberOfReports")),
    }


def _normalise_geometry(geometry: Mapping[str, object]) -> list[dict[str, float]]:
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    raw_points: list[object]
    if geometry_type == "Point" and isinstance(coordinates, list):
        raw_points = [coordinates]
    elif geometry_type == "LineString" and isinstance(coordinates, list):
        raw_points = coordinates
    else:
        return []
    result: list[dict[str, float]] = []
    for item in raw_points[:500]:
        if (
            not isinstance(item, list)
            or len(item) < 2
            or not isinstance(item[0], int | float)
            or not isinstance(item[1], int | float)
        ):
            continue
        longitude = float(item[0])
        latitude = float(item[1])
        if not (-180 <= longitude <= 180 and -90 <= latitude <= 90):
            continue
        result.append({"latitude": latitude, "longitude": longitude})
    return result


def _category_name(value: object) -> str:
    if isinstance(value, int):
        return _CATEGORY_NAMES.get(value, "unknown")
    if isinstance(value, str):
        compact = value.replace("_", "").replace("-", "").lower()
        aliases = {
            "dangerousconditions": "dangerousConditions",
            "laneclosed": "laneClosed",
            "roadclosed": "roadClosed",
            "roadworks": "roadWorks",
            "brokendownvehicle": "brokenDownVehicle",
        }
        return aliases.get(compact, compact)
    return "unknown"


def _magnitude_name(value: object) -> str:
    if isinstance(value, int):
        return _MAGNITUDE_NAMES.get(value, "unknown")
    if isinstance(value, str):
        return value.replace("_", "").replace("-", "").lower()
    return "unknown"


def _hazard_type(category: str) -> str:
    return {
        "accident": "collision",
        "roadWorks": "roadworks",
        "laneClosed": "roadworks",
        "roadClosed": "roadworks",
        "flooding": "flooding",
        "brokenDownVehicle": "stoppedVehicle",
    }.get(category, "other")


def _hazard_severity(category: str, magnitude: str) -> str:
    if category == "roadClosed":
        return "critical"
    return {
        "minor": "advisory",
        "moderate": "caution",
        "major": "serious",
        "undefined": "serious",
    }.get(magnitude, "caution")


def _incident_description(
    properties: Mapping[str, object],
    event_description: str | None,
) -> str:
    parts: list[str] = []
    if event_description:
        parts.append(event_description)
    roads = _short_strings(properties.get("roadNumbers"), maximum=3)
    if roads:
        parts.append(", ".join(roads))
    origin = _short_string(properties.get("from"), 100)
    destination = _short_string(properties.get("to"), 100)
    if origin and destination:
        parts.append(f"{origin} to {destination}")
    elif origin:
        parts.append(origin)
    return " · ".join(parts)[:300] or "Live traffic incident"


def _parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.astimezone(UTC) if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)


def _short_string(value: object, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    return cleaned[:maximum] if cleaned else None


def _short_strings(value: object, *, maximum: int) -> list[str]:
    if not isinstance(value, list):
        return []
    result: list[str] = []
    for item in value:
        cleaned = _short_string(item, 40)
        if cleaned:
            result.append(cleaned)
        if len(result) >= maximum:
            break
    return result


def _optional_nonnegative_int(value: object) -> int | None:
    if not isinstance(value, int | float):
        return None
    return max(0, int(value))


def _quantized_bounds(
    west: float,
    south: float,
    east: float,
    north: float,
) -> tuple[float, float, float, float]:
    step = 0.02
    return (
        math.floor(west / step) * step,
        math.floor(south / step) * step,
        math.ceil(east / step) * step,
        math.ceil(north / step) * step,
    )


def _format_coordinate(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".")


def _retry_after_seconds(headers: Mapping[str, str]) -> int | None:
    raw = headers.get("retry-after")
    if raw is None:
        return None
    try:
        return max(1, min(int(raw), 300))
    except ValueError:
        return None
