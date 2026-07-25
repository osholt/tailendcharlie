from __future__ import annotations

import asyncio
import math
import re
from collections.abc import Callable, Mapping
from datetime import UTC, datetime, timedelta
from typing import Protocol

import httpx

from .config import Settings

_TOMTOM_INCIDENT_URL = "https://api.tomtom.com/maps/orbis/traffic/incidents/details"
_TOMTOM_ROUTE_URL = "https://api.tomtom.com/maps/orbis/routing/routes/calculate"
_TOMTOM_ATTRIBUTES = (
    "incidents(type,geometry(type,coordinates),properties("
    "id,iconCategory,magnitudeOfDelay,events(description,code,iconCategory),"
    "startTime,endTime,from,to,lengthInMeters,delayInSeconds,roadNumbers,"
    "timeValidity,probabilityOfOccurrence,numberOfReports,lastReportTime))"
)
_TOMTOM_ROUTE_ATTRIBUTES = (
    "routes(summary(lengthInMeters,travelDurationInSeconds,"
    "trafficDelayDurationInSeconds,deviationDistanceInMeters,"
    "deviationDurationInSeconds),legs(path),instructions)"
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
# Waze for Cities feed vocabulary. Alert types are an allowlist so an unknown
# category Waze adds later is dropped rather than shown as "other".
_WAZE_ALERT_TYPES: dict[str, tuple[str, str]] = {
    "ACCIDENT": ("collision", "caution"),
    "ROAD_CLOSED": ("roadworks", "critical"),
    "CONSTRUCTION": ("roadworks", "caution"),
    "HAZARD": ("other", "caution"),
    "WEATHERHAZARD": ("other", "caution"),
    "POLICE": ("policeActivity", "serious"),
}
_WAZE_ALERT_LABELS = {
    "ACCIDENT": "Collision reported",
    "ROAD_CLOSED": "Road closed",
    "CONSTRUCTION": "Roadworks",
    "HAZARD": "Road hazard",
    "WEATHERHAZARD": "Weather hazard",
    "POLICE": "Police reported",
}
_WAZE_HAZARD_SUBTYPES: dict[str, tuple[str, str]] = {
    "HAZARD_ON_ROAD_CONSTRUCTION": ("roadworks", "caution"),
    "HAZARD_ON_ROAD_CAR_STOPPED": ("stoppedVehicle", "caution"),
    "HAZARD_ON_ROAD_POT_HOLE": ("pothole", "caution"),
    "HAZARD_ON_ROAD_ROAD_KILL": ("animals", "caution"),
    "HAZARD_ON_ROAD_OBJECT": ("debris", "caution"),
    "HAZARD_ON_ROAD_LANE_CLOSED": ("roadworks", "caution"),
    "HAZARD_ON_ROAD_ICE": ("looseSurface", "serious"),
    "HAZARD_ON_ROAD_OIL": ("looseSurface", "serious"),
    "HAZARD_WEATHER_FLOOD": ("flooding", "serious"),
    "HAZARD_WEATHER": ("other", "caution"),
    "HAZARD_ON_SHOULDER_ANIMALS": ("animals", "caution"),
    "HAZARD_ON_SHOULDER_CAR_STOPPED": ("stoppedVehicle", "advisory"),
    "HAZARD_ON_SHOULDER": ("other", "advisory"),
}
# Enforcement subtype fragments. Waze documents
# HAZARD_ON_ROAD_MOBILE_SPEED_CAMERA; matching on the fragment also catches the
# camera and radar spellings that appear in real partner feeds.
_WAZE_ENFORCEMENT_SUBTYPE_MARKERS = ("CAMERA", "RADAR", "SPEED_TRAP")
# Waze scores crowd reports 0-10. Ordinary hazards below this are noise, but
# enforcement reports are deliberately exempt: riders want a low-confidence
# camera warning far more than they want a missed one.
_WAZE_MINIMUM_RELIABILITY = 5
_WAZE_ENFORCEMENT_TYPES = ("speedCamera", "policeActivity")
_WAZE_MINIMUM_JAM_LEVEL = 3
# The feed is a live snapshot with no per-incident expiry, so a reading is
# trusted only until the next few refreshes would have replaced it.
_WAZE_SNAPSHOT_EXPIRY = timedelta(minutes=10)
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

    @property
    def reroute_configured(self) -> bool: ...

    async def incidents(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]: ...

    async def reroute(
        self,
        *,
        path: list[tuple[float, float]],
        avoid_areas: list[tuple[float, float, float, float]],
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

    @property
    def reroute_configured(self) -> bool:
        return self.configured

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

    async def reroute(
        self,
        *,
        path: list[tuple[float, float]],
        avoid_areas: list[tuple[float, float, float, float]],
    ) -> dict[str, object]:
        if self._api_key is None:
            raise TrafficProviderError("Traffic routing provider is not configured")
        calculated_at = self._clock()
        body = {
            "routePlanningLocations": {
                "origin": {
                    "type": "Point",
                    "coordinates": [path[0][1], path[0][0]],
                },
                "destination": {
                    "type": "Point",
                    "coordinates": [path[-1][1], path[-1][0]],
                },
            },
            "path": {
                "type": "LineString",
                "coordinates": [[longitude, latitude] for latitude, longitude in path],
            },
            "avoidAreas": {
                "rectangles": [
                    {
                        "type": "Feature",
                        "bbox": [west, south, east, north],
                        "geometry": None,
                    }
                    for west, south, east, north in avoid_areas
                ]
            },
            "maxPathAlternativeRoutes": 2,
            "traffic": "live",
            "routeType": "fast",
            "travelMode": "car",
            "guidance": "instructions",
            "instructionPhonetics": "ipa",
        }
        try:
            response = await self._client.post(
                _TOMTOM_ROUTE_URL,
                params={"apiVersion": "3"},
                headers={
                    "TomTom-Api-Key": self._api_key.get_secret_value(),
                    "Attributes": _TOMTOM_ROUTE_ATTRIBUTES,
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "Accept-Language": "en-GB",
                },
                json=body,
            )
        except httpx.HTTPError as error:
            raise TrafficProviderError("Traffic routing provider is unavailable") from error

        if response.status_code == 429:
            raise TrafficProviderError(
                "Traffic routing provider rate limit reached",
                retry_after=_retry_after_seconds(response.headers),
            )
        if response.status_code != 200:
            raise TrafficProviderError("Traffic routing provider request failed")
        if len(response.content) > self._maximum_response_bytes:
            raise TrafficProviderError("Traffic routing response exceeded the safe size limit")
        try:
            payload = response.json()
        except ValueError as error:
            raise TrafficProviderError("Traffic routing provider returned invalid data") from error
        raw_routes = payload.get("routes") if isinstance(payload, Mapping) else None
        if not isinstance(raw_routes, list) or len(raw_routes) < 2:
            raise TrafficProviderError("No traffic-aware alternative route is currently available")
        reference = _normalise_route(raw_routes[0])
        alternatives = [
            route for raw in raw_routes[1:3] if (route := _normalise_route(raw)) is not None
        ]
        if reference is None or not alternatives:
            raise TrafficProviderError("Traffic routing provider returned no usable alternative")
        alternative = min(
            alternatives,
            key=lambda route: (
                int(route["travelDurationSeconds"]),
                int(route["distanceMeters"]),
            ),
        )
        return {
            "provider": "tomtom-orbis",
            "calculatedAt": calculated_at.isoformat().replace("+00:00", "Z"),
            "reference": reference,
            "alternative": alternative,
        }

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


class WazeForCitiesTrafficProvider:
    """Waze for Cities partner feed, normalised to the relay incident contract.

    The feed is a whole-area snapshot rather than a bounded query, so one
    fetch is cached and each viewport is served by filtering that snapshot.
    Waze publishes no routing API, so this provider cannot offer alternatives.
    """

    def __init__(
        self,
        settings: Settings,
        *,
        client: httpx.AsyncClient | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ):
        self._feed_url = settings.waze_traffic_feed_url
        self._cache_seconds = settings.waze_traffic_feed_cache_seconds
        self._maximum_response_bytes = settings.traffic_incident_maximum_response_bytes
        self._clock = clock
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(settings.traffic_provider_timeout_seconds),
            http2=True,
            follow_redirects=False,
        )
        self._owns_client = client is None
        self._lock = asyncio.Lock()
        self._snapshot: tuple[datetime, list[dict[str, object]]] | None = None

    @property
    def configured(self) -> bool:
        return self._feed_url is not None

    @property
    def reroute_configured(self) -> bool:
        return False

    async def incidents(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]:
        if self._feed_url is None:
            raise TrafficProviderError("Traffic incident provider is not configured")
        fetched_at, snapshot = await self._feed()
        incidents = [
            incident
            for incident in snapshot
            if _intersects_bounds(incident, west=west, south=south, east=east, north=north)
        ]
        return {
            "provider": "waze-for-cities",
            "fetchedAt": fetched_at.isoformat().replace("+00:00", "Z"),
            "incidents": incidents[:500],
        }

    async def _feed(self) -> tuple[datetime, list[dict[str, object]]]:
        now = self._clock()
        snapshot = self._snapshot
        if snapshot is not None and now - snapshot[0] < timedelta(seconds=self._cache_seconds):
            return snapshot

        async with self._lock:
            now = self._clock()
            snapshot = self._snapshot
            if snapshot is not None and now - snapshot[0] < timedelta(seconds=self._cache_seconds):
                return snapshot
            fresh = (now, await self._fetch(now))
            self._snapshot = fresh
            return fresh

    async def _fetch(self, fetched_at: datetime) -> list[dict[str, object]]:
        assert self._feed_url is not None
        try:
            response = await self._client.get(
                self._feed_url.get_secret_value(),
                headers={"Accept": "application/json"},
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
        if not isinstance(payload, Mapping):
            raise TrafficProviderError("Traffic incident provider returned invalid data")
        raw_alerts = payload.get("alerts")
        raw_jams = payload.get("jams")
        if not isinstance(raw_alerts, list) and not isinstance(raw_jams, list):
            raise TrafficProviderError("Traffic incident provider returned invalid data")

        incidents: list[dict[str, object]] = []
        if isinstance(raw_alerts, list):
            incidents.extend(
                incident
                for item in raw_alerts[:2000]
                if (incident := _normalise_waze_alert(item, fetched_at)) is not None
            )
        if isinstance(raw_jams, list):
            incidents.extend(
                incident
                for item in raw_jams[:2000]
                if (incident := _normalise_waze_jam(item, fetched_at)) is not None
            )
        return incidents

    async def reroute(
        self,
        *,
        path: list[tuple[float, float]],
        avoid_areas: list[tuple[float, float, float, float]],
    ) -> dict[str, object]:
        raise TrafficProviderError("Waze publishes no route alternatives")

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()


class PreferredTrafficProvider:
    """Waze incidents when its feed is configured, TomTom otherwise.

    Waze has no routing API, so alternatives always come from TomTom and the
    reroute surface reports itself unconfigured when only Waze is available.
    """

    def __init__(
        self,
        *,
        preferred: TrafficIncidentProvider,
        fallback: TrafficIncidentProvider,
    ):
        self._preferred = preferred
        self._fallback = fallback

    @property
    def configured(self) -> bool:
        return self._preferred.configured or self._fallback.configured

    @property
    def reroute_configured(self) -> bool:
        return self._preferred.reroute_configured or self._fallback.reroute_configured

    async def incidents(
        self,
        *,
        west: float,
        south: float,
        east: float,
        north: float,
    ) -> dict[str, object]:
        if self._preferred.configured:
            try:
                return await self._preferred.incidents(
                    west=west,
                    south=south,
                    east=east,
                    north=north,
                )
            except TrafficProviderError:
                # A degraded preferred feed must not hide a healthy fallback,
                # but with no fallback the original failure is what callers
                # need to see.
                if not self._fallback.configured:
                    raise
        if not self._fallback.configured:
            raise TrafficProviderError("Traffic incident provider is not configured")
        return await self._fallback.incidents(west=west, south=south, east=east, north=north)

    async def reroute(
        self,
        *,
        path: list[tuple[float, float]],
        avoid_areas: list[tuple[float, float, float, float]],
    ) -> dict[str, object]:
        for provider in (self._preferred, self._fallback):
            if provider.reroute_configured:
                return await provider.reroute(path=path, avoid_areas=avoid_areas)
        raise TrafficProviderError("Traffic routing provider is not configured")

    async def close(self) -> None:
        await self._preferred.close()
        await self._fallback.close()


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


def validate_uk_reroute(
    path: list[tuple[float, float]],
    avoid_areas: list[tuple[float, float, float, float]],
) -> None:
    if len(path) < 2 or len(path) > 1000:
        raise ValueError("Traffic rerouting requires 2 to 1000 route points")
    if not 1 <= len(avoid_areas) <= 10:
        raise ValueError("Traffic rerouting requires 1 to 10 avoid areas")
    for latitude, longitude in path:
        if not 49.0 <= latitude <= 61.5 or not -11.5 <= longitude <= 3.0:
            raise ValueError("Traffic rerouting is currently available only for UK routes")
    for west, south, east, north in avoid_areas:
        validate_uk_incident_bounds(west, south, east, north)
        latitude_km = (north - south) * 111.32
        longitude_km = (east - west) * 111.32 * math.cos(math.radians((south + north) / 2))
        if latitude_km * longitude_km > 25:
            raise ValueError("A traffic reroute avoid area is too large")


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


def _intersects_bounds(
    incident: Mapping[str, object],
    *,
    west: float,
    south: float,
    east: float,
    north: float,
) -> bool:
    geometry = incident.get("geometry")
    if not isinstance(geometry, list):
        return False
    for point in geometry:
        if not isinstance(point, Mapping):
            continue
        latitude = point.get("latitude")
        longitude = point.get("longitude")
        if not isinstance(latitude, int | float) or not isinstance(longitude, int | float):
            continue
        if south <= latitude <= north and west <= longitude <= east:
            return True
    return False


def _normalise_waze_alert(raw: object, fetched_at: datetime) -> dict[str, object] | None:
    if not isinstance(raw, Mapping):
        return None
    alert_id = raw.get("uuid")
    if not isinstance(alert_id, str) or not alert_id or len(alert_id) > 200:
        return None
    alert_type = raw.get("type")
    if not isinstance(alert_type, str):
        return None
    subtype = raw.get("subtype") if isinstance(raw.get("subtype"), str) else ""
    mapped = _WAZE_ALERT_TYPES.get(alert_type)
    if mapped is None:
        return None
    point = _waze_point(raw.get("location"))
    if point is None:
        return None

    hazard_type, severity = mapped
    if any(marker in subtype.upper() for marker in _WAZE_ENFORCEMENT_SUBTYPE_MARKERS):
        hazard_type, severity = ("speedCamera", "serious")
    elif alert_type in {"HAZARD", "WEATHERHAZARD"}:
        hazard_type, severity = _waze_hazard_subtype(subtype)
    elif alert_type == "ACCIDENT" and subtype == "ACCIDENT_MAJOR":
        severity = "serious"

    reliability = raw.get("reliability")
    if (
        hazard_type not in _WAZE_ENFORCEMENT_TYPES
        and isinstance(reliability, int | float)
        and reliability < _WAZE_MINIMUM_RELIABILITY
    ):
        return None

    observed_at = _parse_millis(raw.get("pubMillis")) or fetched_at
    thumbs_up = _optional_nonnegative_int(raw.get("nThumbsUp")) or 0
    return {
        "id": f"alert-{alert_id}",
        "type": hazard_type,
        "severity": severity,
        "category": _short_string(subtype, 60) or alert_type.lower(),
        "magnitude": "unknown",
        "description": _waze_description(raw, _WAZE_ALERT_LABELS.get(alert_type, "Road hazard")),
        "geometry": [point],
        "observedAt": observed_at.isoformat().replace("+00:00", "Z"),
        "expiresAt": (fetched_at + _WAZE_SNAPSHOT_EXPIRY).isoformat().replace("+00:00", "Z"),
        "reportCount": thumbs_up + 1,
    }


def _normalise_waze_jam(raw: object, fetched_at: datetime) -> dict[str, object] | None:
    if not isinstance(raw, Mapping):
        return None
    jam_id = raw.get("uuid")
    if not isinstance(jam_id, str | int):
        return None
    level = raw.get("level")
    delay_seconds = _optional_nonnegative_int(raw.get("delay"))
    if not isinstance(level, int) or level < _WAZE_MINIMUM_JAM_LEVEL:
        return None
    points: list[dict[str, float]] = []
    line = raw.get("line")
    if isinstance(line, list):
        for item in line[:500]:
            vertex = _waze_point(item)
            if vertex is not None:
                points.append(vertex)
    if not points:
        return None

    # Level 5 is Waze's blocked state; 4 is a standstill. Both are worth a
    # reroute review, lighter congestion is context only.
    severity = "serious" if level >= 4 or (delay_seconds or 0) >= 600 else "caution"
    street = _short_string(raw.get("street"), 100)
    description_parts = [f"Heavy traffic (Waze level {level})"]
    if street:
        description_parts.append(street)
    if delay_seconds:
        description_parts.append(f"{round(delay_seconds / 60)} min delay")
    return {
        "id": f"jam-{jam_id}",
        "type": "other",
        "severity": severity,
        "category": "jam",
        "magnitude": "major" if severity == "serious" else "moderate",
        "description": " · ".join(description_parts)[:300],
        "geometry": points,
        "observedAt": (_parse_millis(raw.get("pubMillis")) or fetched_at)
        .isoformat()
        .replace("+00:00", "Z"),
        "expiresAt": (fetched_at + _WAZE_SNAPSHOT_EXPIRY).isoformat().replace("+00:00", "Z"),
        "delaySeconds": delay_seconds,
        "reportCount": 1,
    }


def _waze_point(raw: object) -> dict[str, float] | None:
    if not isinstance(raw, Mapping):
        return None
    longitude = raw.get("x")
    latitude = raw.get("y")
    if not isinstance(longitude, int | float) or not isinstance(latitude, int | float):
        return None
    if not (-180 <= longitude <= 180 and -90 <= latitude <= 90):
        return None
    return {"latitude": float(latitude), "longitude": float(longitude)}


def _waze_hazard_subtype(subtype: str) -> tuple[str, str]:
    for prefix, mapped in _WAZE_HAZARD_SUBTYPES.items():
        if subtype.startswith(prefix):
            return mapped
    return ("other", "caution")


def _waze_description(raw: Mapping[str, object], fallback: str) -> str:
    parts: list[str] = []
    description = _short_string(raw.get("reportDescription"), 160)
    if description:
        parts.append(description)
    else:
        parts.append(fallback)
    street = _short_string(raw.get("street"), 100)
    if street:
        parts.append(street)
    return " · ".join(parts)[:300]


def _parse_millis(value: object) -> datetime | None:
    if not isinstance(value, int | float) or isinstance(value, bool):
        return None
    try:
        return datetime.fromtimestamp(float(value) / 1000, UTC)
    except (OverflowError, OSError, ValueError):
        return None


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


def _normalise_route(raw: object) -> dict[str, object] | None:
    if not isinstance(raw, Mapping):
        return None
    summary = raw.get("summary")
    legs = raw.get("legs")
    if not isinstance(summary, Mapping) or not isinstance(legs, list):
        return None
    distance = _optional_nonnegative_int(summary.get("lengthInMeters"))
    duration = _optional_nonnegative_int(summary.get("travelDurationInSeconds"))
    if distance is None or duration is None:
        return None
    points: list[dict[str, float]] = []
    for leg in legs:
        if not isinstance(leg, Mapping):
            continue
        geometry = leg.get("path")
        if not isinstance(geometry, Mapping):
            continue
        leg_points = _normalise_geometry(geometry)
        if points and leg_points and points[-1] == leg_points[0]:
            leg_points = leg_points[1:]
        points.extend(leg_points)
        if len(points) > 5000:
            return None
    if len(points) < 2:
        return None
    result: dict[str, object] = {
        "distanceMeters": distance,
        "travelDurationSeconds": duration,
        "trafficDelaySeconds": _optional_nonnegative_int(
            summary.get("trafficDelayDurationInSeconds")
        )
        or 0,
        "points": points,
        "maneuvers": _normalise_instructions(raw.get("instructions")),
    }
    deviation_distance = _optional_nonnegative_int(summary.get("deviationDistanceInMeters"))
    deviation_duration = _optional_nonnegative_int(summary.get("deviationDurationInSeconds"))
    if deviation_distance is not None:
        result["deviationDistanceMeters"] = deviation_distance
    if deviation_duration is not None:
        result["deviationDurationSeconds"] = deviation_duration
    return result


def _normalise_instructions(raw: object) -> list[dict[str, object]]:
    if not isinstance(raw, list):
        return []
    result: list[dict[str, object]] = []
    for item in raw[:1000]:
        if not isinstance(item, Mapping):
            continue
        maneuver = item.get("maneuver")
        point = item.get("maneuverPoint")
        if not isinstance(maneuver, str) or not isinstance(point, Mapping):
            continue
        latitude = point.get("latitude")
        longitude = point.get("longitude")
        if not isinstance(latitude, int | float) or not isinstance(longitude, int | float):
            continue
        mapped = _normalise_maneuver_code(maneuver)
        next_road = item.get("nextRoadInformation")
        road_name = None
        road_ref = None
        if isinstance(next_road, Mapping):
            street_name = next_road.get("streetName")
            if isinstance(street_name, Mapping):
                road_name = _short_string(street_name.get("text"), 120)
            shields = next_road.get("roadShields")
            if isinstance(shields, list):
                for shield in shields:
                    if not isinstance(shield, Mapping):
                        continue
                    number = shield.get("roadNumber")
                    if isinstance(number, Mapping):
                        road_ref = _short_string(number.get("text"), 40)
                    if road_ref:
                        break
        instruction: dict[str, object] = {
            "latitude": float(latitude),
            "longitude": float(longitude),
            "type": mapped[0],
        }
        if mapped[1] is not None:
            instruction["modifier"] = mapped[1]
        if road_name is not None:
            instruction["name"] = road_name
        if road_ref is not None:
            instruction["ref"] = road_ref
        exit_number = _optional_nonnegative_int(item.get("roundaboutExitNumber"))
        if exit_number is not None:
            instruction["exitNumber"] = exit_number
        driving_side = item.get("drivingSide")
        if driving_side in {"left", "right"}:
            instruction["drivingSide"] = driving_side
        message = _short_string(
            item.get("message") or item.get("instructionMessage"),
            240,
        )
        if message is not None:
            instruction["message"] = message
        result.append(instruction)
    return result


def _normalise_maneuver_code(value: str) -> tuple[str, str | None]:
    direct = {
        "depart": ("depart", None),
        "arrive": ("arrive", None),
        "arriveLeft": ("arrive", "left"),
        "arriveRight": ("arrive", "right"),
        "arriveAhead": ("arrive", "straight"),
        "continueStraight": ("continue", "straight"),
        "makeUTurn": ("turn", "uturn"),
        "keepLeft": ("fork", "left"),
        "keepRight": ("fork", "right"),
        "keepCenter": ("fork", "straight"),
        "exitMotorwayLeft": ("off ramp", "left"),
        "exitMotorwayRight": ("off ramp", "right"),
        "exitMotorwayMiddle": ("off ramp", "straight"),
        "switchMotorwayLeft": ("fork", "left"),
        "switchMotorwayRight": ("fork", "right"),
        "switchMotorwayMiddle": ("fork", "straight"),
        "mergeLeftLane": ("merge", "left"),
        "mergeRightLane": ("merge", "right"),
        "exitRoundabout": ("exit roundabout", None),
    }
    if value in direct:
        return direct[value]
    if value.startswith("turn"):
        return "turn", _camel_direction(value.removeprefix("turn"))
    if value.startswith("roundabout"):
        return "roundabout", _camel_direction(value.removeprefix("roundabout"))
    return value, None


def _camel_direction(value: str) -> str | None:
    if not value:
        return None
    spaced = re.sub(r"(?<!^)(?=[A-Z])", " ", value).lower()
    return {
        "back": "uturn",
        "straight": "straight",
    }.get(spaced, spaced)


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
