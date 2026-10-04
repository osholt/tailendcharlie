#!/usr/bin/env python3
"""Find mapped speed limits that a rider's own GPX says may be stale (#852).

The speed-limit sign in the app is not an inference. It reads the OpenStreetMap
`maxspeed` tag through Valhalla, so a road mapped 20 mph shows 20 even where the
sign says 30. In Wales a great many limits were mapped 20 during the 2023-24
rollout and the councils have since returned some roads to 30; nobody edited the
map. This tool finds those roads from a ride that went along them:

  1. It computes the rider's *sustained* speed over a short window (20 s by
     default), so a burst past a lorry is not mistaken for a pace.
  2. It asks Valhalla `trace_attributes` what limit the map records along the
     track, in chunks of at most 300 points and no faster than one request a
     second, because the public instance is shared.
  3. It reports every stretch where the sustained speed exceeded the mapped
     limit by at least a threshold (7 mph by default) for at least a minimum
     distance (150 m by default): the OSM way ids, the road's reference or name,
     where it is, the mapped limit and the median speed.

A report line is a lead, not a finding. A rider can exceed a limit that is
correctly mapped, so the next step is to check the sign - ideally a photograph
or street-level imagery - and, if the map is wrong, to edit it with
`source:maxspeed=sign`. Nothing here edits OpenStreetMap or sends the track
anywhere except to the Valhalla service named by `--url`.

Standard library only. Nothing is written unless `--json` says where.

    python3 tools/speed_limit_audit/speed_limit_audit.py ride.gpx
    python3 tools/speed_limit_audit/speed_limit_audit.py ride.gpx --threshold-mph 5
    python3 tools/speed_limit_audit/speed_limit_audit.py ride.gpx --dry-run
"""

from __future__ import annotations

import argparse
import calendar
import json
import math
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field

DEFAULT_URL = "https://valhalla1.openstreetmap.de/trace_attributes"
USER_AGENT = "TailEndCharlie-speed-limit-audit/1.0 (+https://github.com/osholt/tailendcharlie)"

# Valhalla's public instance caps a trace by path length and by request rate. The
# app's own lookups are one a second at most; so is this.
MAX_POINTS_PER_REQUEST = 300
DEFAULT_REQUEST_INTERVAL_SECONDS = 1.1
DEFAULT_WINDOW_SECONDS = 20.0
DEFAULT_THRESHOLD_MPH = 7.0
DEFAULT_MIN_DISTANCE_METRES = 150.0

EARTH_RADIUS_METRES = 6371008.8
METRES_PER_SECOND_TO_MPH = 2.236936
KMH_PER_MPH = 1.609344

# What is asked of trace_attributes, and nothing else: the limit, the way it came
# from, what the road is called, and which edge each fix was matched to.
REQUESTED_ATTRIBUTES = (
    "edge.speed_limit",
    "edge.way_id",
    "edge.names",
    "edge.road_class",
    "matched.edge_index",
    "matched.type",
)


class AuditError(Exception):
    """Something the operator can act on: a bad file, an unreachable service."""


# --- reading the ride -------------------------------------------------------


@dataclass(frozen=True)
class TrackPoint:
    latitude: float
    longitude: float
    time: float  # seconds since the epoch


_TIME = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(\.\d+)?" r"(Z|[+-]\d{2}(?::?\d{2})?)?$"
)


def parse_time(text: str) -> float:
    """Seconds since the epoch for an ISO 8601 GPX timestamp.

    Written out rather than left to `datetime.fromisoformat`, which before
    Python 3.11 rejects a `Z` suffix and fractional seconds that are not exactly
    three or six digits - both of which real GPX files contain.
    """
    match = _TIME.match(text.strip())
    if match is None:
        raise ValueError(f"Not an ISO 8601 time: {text!r}")
    year, month, day, hour, minute, second = (int(match.group(i)) for i in range(1, 7))
    seconds = calendar.timegm((year, month, day, hour, minute, second))
    if match.group(7):
        seconds += float(match.group(7))
    offset = match.group(8)
    if offset and offset != "Z":
        sign = -1 if offset[0] == "-" else 1
        digits = offset[1:].replace(":", "")
        seconds -= sign * (int(digits[:2]) * 3600 + int(digits[2:4] or 0) * 60)
    return seconds


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def read_gpx(source) -> list[list[TrackPoint]]:
    """The timed track points of a GPX file, one list per track segment.

    A segment is where the recorder stopped and started, so segments are never
    joined: a speed across the gap would be a speed nobody rode. Points without a
    time are dropped, since a speed cannot be worked out from them. GPX 1.0 and
    1.1 are both read.
    """
    try:
        root = ET.parse(source).getroot()  # noqa: S314 - the operator's own file
    except (ET.ParseError, OSError) as error:
        raise AuditError(f"Could not read the GPX file: {error}") from error
    segments: list[list[TrackPoint]] = []
    for element in root.iter():
        if _local(element.tag) != "trkseg":
            continue
        points: list[TrackPoint] = []
        for child in element:
            if _local(child.tag) != "trkpt":
                continue
            stamp = next((c.text for c in child if _local(c.tag) == "time" and c.text), None)
            if stamp is None:
                continue
            try:
                points.append(
                    TrackPoint(
                        latitude=float(child.attrib["lat"]),
                        longitude=float(child.attrib["lon"]),
                        time=parse_time(stamp),
                    )
                )
            except (KeyError, ValueError):
                continue
        if len(points) >= 2:
            segments.append(points)
    if not segments:
        raise AuditError(
            "The GPX file has no recorded track with timed points, so there is no speed to "
            "compare. A planned route has no times."
        )
    return segments


def distance_metres(first: TrackPoint, second: TrackPoint) -> float:
    lat1, lat2 = math.radians(first.latitude), math.radians(second.latitude)
    delta_lat = lat2 - lat1
    delta_lon = math.radians(second.longitude - first.longitude)
    a = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    return 2 * EARTH_RADIUS_METRES * math.asin(math.sqrt(a))


def sustained_speeds_mph(
    points: Sequence[TrackPoint], window_seconds: float = DEFAULT_WINDOW_SECONDS
) -> list[float | None]:
    """The speed each fix was sustaining, in mph.

    Distance travelled along the track across a window centred on the fix, over
    the time it took. A window rather than the speed between two fixes, which on a
    phone's GPS is noise at one hertz; and distance along the track rather than
    straight-line, so a bend does not read as slowing down. None where the window
    holds no other fix, which is a gap in the recording and not a standstill.
    """
    cumulative = [0.0]
    for index in range(1, len(points)):
        cumulative.append(cumulative[-1] + distance_metres(points[index - 1], points[index]))
    half = window_seconds / 2
    speeds: list[float | None] = []
    first = 0
    last = 0
    for index, point in enumerate(points):
        while points[first].time < point.time - half:
            first += 1
        last = max(last, index)
        while last + 1 < len(points) and points[last + 1].time <= point.time + half:
            last += 1
        elapsed = points[last].time - points[first].time
        if last == first or elapsed <= 0:
            speeds.append(None)
            continue
        speeds.append((cumulative[last] - cumulative[first]) / elapsed * METRES_PER_SECOND_TO_MPH)
    return speeds


# --- asking Valhalla --------------------------------------------------------


@dataclass(frozen=True)
class MatchedRoad:
    """What the map records for the road a fix was matched to."""

    way_id: int | None
    names: tuple[str, ...]
    road_class: str | None
    limit_mph: int | None


Post = Callable[[str, dict, dict, float], tuple[int, object]]


def post_json(url: str, body: dict, headers: dict, timeout: float) -> tuple[int, object]:
    """POST JSON and return (status, decoded body). The only place that touches the network."""
    if not url.lower().startswith("https://"):
        raise AuditError("The speed-limit service must be an https:// URL.")
    request = urllib.request.Request(  # noqa: S310 - scheme checked above
        url, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except ValueError:
            return error.code, None
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        raise AuditError(f"Could not reach the speed-limit service: {error}") from error


def limit_mph(kilometres_per_hour: object) -> int | None:
    """A Valhalla limit in km/h as whole mph. Non-numeric limits (`unlimited`) are None."""
    if isinstance(kilometres_per_hour, bool):
        return None
    if not isinstance(kilometres_per_hour, int) and not isinstance(kilometres_per_hour, float):
        return None
    if kilometres_per_hour <= 0:
        return None
    return round(kilometres_per_hour / KMH_PER_MPH)


class ValhallaTrace:
    """`trace_attributes`, one polite request at a time.

    The interval is kept between the *starts* of requests, so a slow answer does
    not make the next one wait longer than it has to and a fast one does not make
    it early. A rate-limited or overloaded answer is retried once after a pause;
    anything else is reported and the chunk is left unchecked rather than guessed.
    """

    def __init__(
        self,
        url: str = DEFAULT_URL,
        *,
        post: Post = post_json,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        interval_seconds: float = DEFAULT_REQUEST_INTERVAL_SECONDS,
        retry_delay_seconds: float = 5.0,
        timeout_seconds: float = 60.0,
        warn: Callable[[str], None] | None = None,
    ) -> None:
        self.url = url
        self._post = post
        self._sleep = sleep
        self._clock = clock
        self.interval_seconds = interval_seconds
        self.retry_delay_seconds = retry_delay_seconds
        self.timeout_seconds = timeout_seconds
        self._warn = warn or (lambda message: print(message, file=sys.stderr))
        self._last_request: float | None = None
        self.requests = 0

    def _wait_turn(self) -> None:
        if self._last_request is not None:
            wait = self.interval_seconds - (self._clock() - self._last_request)
            if wait > 0:
                self._sleep(wait)
        self._last_request = self._clock()

    def match(self, points: Sequence[TrackPoint]) -> list[MatchedRoad | None]:
        """The road each of [points] was matched to; None for a fix that was not matched.

        At most MAX_POINTS_PER_REQUEST points, which is the caller's to enforce
        by chunking. Returns all None, after a warning, when the service gave no
        usable answer.
        """
        if len(points) > MAX_POINTS_PER_REQUEST:
            raise ValueError(f"A request carries at most {MAX_POINTS_PER_REQUEST} points.")
        unchecked: list[MatchedRoad | None] = [None] * len(points)
        if len(points) < 2:
            return unchecked
        body = {
            "shape": [{"lat": p.latitude, "lon": p.longitude} for p in points],
            "costing": "motorcycle",
            "shape_match": "map_snap",
            "filters": {"action": "include", "attributes": list(REQUESTED_ATTRIBUTES)},
        }
        headers = {"Content-Type": "application/json", "User-Agent": USER_AGENT}
        for attempt in range(2):
            self._wait_turn()
            self.requests += 1
            try:
                status, decoded = self._post(self.url, body, headers, self.timeout_seconds)
            except AuditError as error:
                self._warn(f"warning: {error}; {len(points)} fixes left unchecked")
                return unchecked
            if status in (429, 502, 503, 504) and attempt == 0:
                self._warn(f"warning: the service answered {status}; retrying once")
                self._sleep(self.retry_delay_seconds)
                continue
            if status != 200 or not isinstance(decoded, dict):
                detail = decoded.get("error") if isinstance(decoded, dict) else None
                self._warn(
                    f"warning: the service answered {status}"
                    f"{f' ({detail})' if detail else ''}; {len(points)} fixes left unchecked"
                )
                return unchecked
            return self._read(decoded, len(points))
        return unchecked

    @staticmethod
    def _read(decoded: dict, count: int) -> list[MatchedRoad | None]:
        edges = decoded.get("edges")
        matches = decoded.get("matched_points")
        if not isinstance(edges, list) or not isinstance(matches, list):
            return [None] * count
        result: list[MatchedRoad | None] = []
        for index in range(count):
            match = matches[index] if index < len(matches) else None
            edge_index = match.get("edge_index") if isinstance(match, dict) else None
            if (
                not isinstance(match, dict)
                or match.get("type") not in ("matched", "interpolated")
                or not isinstance(edge_index, int)
                or not 0 <= edge_index < len(edges)
                or not isinstance(edges[edge_index], dict)
            ):
                result.append(None)
                continue
            edge = edges[edge_index]
            names = edge.get("names")
            way_id = edge.get("way_id")
            result.append(
                MatchedRoad(
                    way_id=way_id if isinstance(way_id, int) else None,
                    names=tuple(n for n in names if isinstance(n, str))
                    if isinstance(names, list)
                    else (),
                    road_class=edge.get("road_class")
                    if isinstance(edge.get("road_class"), str)
                    else None,
                    limit_mph=limit_mph(edge.get("speed_limit")),
                )
            )
        return result


def chunks(count: int, size: int = MAX_POINTS_PER_REQUEST) -> list[range]:
    """Consecutive index ranges of at most [size], covering 0..count."""
    return [range(start, min(start + size, count)) for start in range(0, count, size)]


# --- finding the stretches --------------------------------------------------


@dataclass(frozen=True)
class Fix:
    """One fix, with the speed it was sustaining and the road the map put it on."""

    segment: int
    point: TrackPoint
    mph: float | None
    road: MatchedRoad | None

    @property
    def limit_mph(self) -> int | None:
        return self.road.limit_mph if self.road else None


@dataclass(frozen=True)
class Stretch:
    """A run of fixes sustaining more than the mapped limit by the threshold."""

    segment: int
    limit_mph: int
    median_mph: float
    maximum_mph: float
    distance_metres: float
    duration_seconds: float
    way_ids: tuple[int, ...]
    names: tuple[str, ...]
    road_classes: tuple[str, ...]
    start: TrackPoint
    end: TrackPoint
    fixes: int = field(default=0, compare=False)


def find_stretches(
    fixes: Iterable[Fix],
    threshold_mph: float = DEFAULT_THRESHOLD_MPH,
    min_distance_metres: float = DEFAULT_MIN_DISTANCE_METRES,
) -> list[Stretch]:
    """Stretches where the sustained speed beat the mapped limit by the threshold.

    A stretch is consecutive fixes in one segment that all beat the limit, with
    the same limit throughout: a stretch that crosses from a 20 mph way into a 30
    mph one is two findings, because only one of them can be a stale limit. It is
    reported only if the fixes cover [min_distance_metres]; a hundred metres at 40
    through a 30 is a driver overtaking, and no evidence about the sign.
    """
    stretches: list[Stretch] = []
    run: list[Fix] = []

    def close() -> None:
        stretch = _stretch_of(run, min_distance_metres)
        if stretch is not None:
            stretches.append(stretch)
        run.clear()

    for fix in fixes:
        limit = fix.limit_mph
        over = fix.mph is not None and limit is not None and fix.mph - limit >= threshold_mph
        if not over:
            close()
            continue
        if run and (fix.segment != run[-1].segment or limit != run[-1].limit_mph):
            close()
        run.append(fix)
    close()
    return stretches


def _stretch_of(run: Sequence[Fix], min_distance_metres: float) -> Stretch | None:
    if len(run) < 2:
        return None
    distance = sum(
        distance_metres(run[index - 1].point, run[index].point) for index in range(1, len(run))
    )
    if distance < min_distance_metres:
        return None
    speeds = [fix.mph for fix in run if fix.mph is not None]
    ways: list[int] = []
    names: list[str] = []
    classes: list[str] = []
    for fix in run:
        road = fix.road
        if road is None:
            continue
        if road.way_id is not None and road.way_id not in ways:
            ways.append(road.way_id)
        for name in road.names:
            if name not in names:
                names.append(name)
        if road.road_class and road.road_class not in classes:
            classes.append(road.road_class)
    return Stretch(
        segment=run[0].segment,
        limit_mph=run[0].limit_mph or 0,
        median_mph=statistics.median(speeds),
        maximum_mph=max(speeds),
        distance_metres=distance,
        duration_seconds=run[-1].point.time - run[0].point.time,
        way_ids=tuple(ways),
        names=tuple(names),
        road_classes=tuple(classes),
        start=run[0].point,
        end=run[-1].point,
        fixes=len(run),
    )


# --- the audit --------------------------------------------------------------


@dataclass
class AuditResult:
    stretches: list[Stretch]
    fixes: int
    with_limit: int
    without_limit: int
    unmatched_or_unchecked: int
    requests: int


def audit(
    segments: Sequence[Sequence[TrackPoint]],
    trace: ValhallaTrace,
    *,
    window_seconds: float = DEFAULT_WINDOW_SECONDS,
    threshold_mph: float = DEFAULT_THRESHOLD_MPH,
    min_distance_metres: float = DEFAULT_MIN_DISTANCE_METRES,
) -> AuditResult:
    fixes: list[Fix] = []
    for number, points in enumerate(segments):
        speeds = sustained_speeds_mph(points, window_seconds)
        roads: list[MatchedRoad | None] = []
        for indexes in chunks(len(points)):
            roads.extend(trace.match([points[i] for i in indexes]))
        fixes.extend(
            Fix(segment=number, point=points[index], mph=speeds[index], road=roads[index])
            for index in range(len(points))
        )
    return AuditResult(
        stretches=find_stretches(fixes, threshold_mph, min_distance_metres),
        fixes=len(fixes),
        with_limit=sum(1 for fix in fixes if fix.limit_mph is not None),
        without_limit=sum(1 for fix in fixes if fix.road is not None and fix.limit_mph is None),
        unmatched_or_unchecked=sum(1 for fix in fixes if fix.road is None),
        requests=trace.requests,
    )


def request_count(segments: Sequence[Sequence[TrackPoint]]) -> int:
    return sum(len(chunks(len(points))) for points in segments)


# --- the report -------------------------------------------------------------


def _clock(seconds: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))


def _place(point: TrackPoint) -> str:
    return f"{point.latitude:.5f},{point.longitude:.5f}"


def format_report(
    result: AuditResult,
    *,
    threshold_mph: float = DEFAULT_THRESHOLD_MPH,
    min_distance_metres: float = DEFAULT_MIN_DISTANCE_METRES,
    window_seconds: float = DEFAULT_WINDOW_SECONDS,
) -> str:
    lines = [
        f"Stretches where the sustained speed ({window_seconds:g} s window) beat the mapped "
        f"limit by {threshold_mph:g} mph or more for at least {min_distance_metres:g} m",
        "",
    ]
    if not result.stretches:
        lines.append("None.")
    for number, stretch in enumerate(result.stretches, start=1):
        road = ", ".join(stretch.names) or "(unnamed)"
        ways = ", ".join(f"way/{way}" for way in stretch.way_ids) or "(no way id)"
        lines += [
            f"{number}. {road} - mapped {stretch.limit_mph} mph, median "
            f"{stretch.median_mph:.0f} mph (+{stretch.median_mph - stretch.limit_mph:.0f}), "
            f"{stretch.distance_metres:.0f} m",
            f"   {ways}",
            *(f"   https://www.openstreetmap.org/way/{way}" for way in stretch.way_ids),
            f"   from {_place(stretch.start)} to {_place(stretch.end)} at "
            f"{_clock(stretch.start.time)}"
            + (f" ({stretch.road_classes[0]})" if stretch.road_classes else ""),
        ]
    lines += [
        "",
        f"{result.fixes} fixes: {result.with_limit} on a road with a mapped limit, "
        f"{result.without_limit} on a road with none, {result.unmatched_or_unchecked} not "
        f"matched or not checked; {result.requests} request(s) to the service.",
    ]
    return "\n".join(lines)


def result_json(
    result: AuditResult,
    *,
    threshold_mph: float,
    min_distance_metres: float,
    window_seconds: float,
) -> dict:
    return {
        "parameters": {
            "windowSeconds": window_seconds,
            "thresholdMph": threshold_mph,
            "minimumDistanceMetres": min_distance_metres,
        },
        "summary": {
            "fixes": result.fixes,
            "withMappedLimit": result.with_limit,
            "withoutMappedLimit": result.without_limit,
            "unmatchedOrUnchecked": result.unmatched_or_unchecked,
            "requests": result.requests,
        },
        "stretches": [
            {
                "wayIds": list(stretch.way_ids),
                "names": list(stretch.names),
                "roadClasses": list(stretch.road_classes),
                "mappedLimitMph": stretch.limit_mph,
                "medianMph": round(stretch.median_mph, 1),
                "maximumMph": round(stretch.maximum_mph, 1),
                "distanceMetres": round(stretch.distance_metres),
                "durationSeconds": round(stretch.duration_seconds),
                "start": {
                    "lat": round(stretch.start.latitude, 5),
                    "lon": round(stretch.start.longitude, 5),
                    "time": _clock(stretch.start.time),
                },
                "end": {
                    "lat": round(stretch.end.latitude, 5),
                    "lon": round(stretch.end.longitude, 5),
                    "time": _clock(stretch.end.time),
                },
            }
            for stretch in result.stretches
        ],
    }


# --- command line -----------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Find roads whose mapped speed limit a ride's own GPX says may be stale.",
    )
    parser.add_argument("gpx", help="a recorded ride (GPX with timed track points)")
    parser.add_argument("--url", default=DEFAULT_URL, help="Valhalla trace_attributes endpoint")
    parser.add_argument(
        "--threshold-mph",
        type=float,
        default=DEFAULT_THRESHOLD_MPH,
        help="how far over the mapped limit counts (default %(default)s)",
    )
    parser.add_argument(
        "--min-distance-m",
        type=float,
        default=DEFAULT_MIN_DISTANCE_METRES,
        help="how far it must be sustained (default %(default)s)",
    )
    parser.add_argument(
        "--window-s",
        type=float,
        default=DEFAULT_WINDOW_SECONDS,
        help="seconds the speed is averaged over (default %(default)s)",
    )
    parser.add_argument(
        "--interval-s",
        type=float,
        default=DEFAULT_REQUEST_INTERVAL_SECONDS,
        help="least seconds between requests; do not go below 1 on the public instance",
    )
    parser.add_argument("--json", metavar="PATH", help="also write the report as JSON")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="read the ride and say what would be asked, without asking",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    post: Post = post_json,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    args = build_parser().parse_args(argv)
    if args.interval_s < 1.0:
        print("The interval may not be under one second.", file=sys.stderr)
        return 2
    try:
        segments = read_gpx(args.gpx)
    except AuditError as error:
        print(error, file=sys.stderr)
        return 2
    requests = request_count(segments)
    fixes = sum(len(points) for points in segments)
    print(
        f"{fixes} timed fixes in {len(segments)} segment(s): {requests} request(s), about "
        f"{requests * args.interval_s:.0f} s.",
        file=sys.stderr,
    )
    if args.dry_run:
        return 0
    trace = ValhallaTrace(
        args.url, post=post, sleep=sleep, clock=clock, interval_seconds=args.interval_s
    )
    try:
        result = audit(
            segments,
            trace,
            window_seconds=args.window_s,
            threshold_mph=args.threshold_mph,
            min_distance_metres=args.min_distance_m,
        )
    except AuditError as error:
        print(error, file=sys.stderr)
        return 2
    if result.with_limit == 0 and result.without_limit == 0:
        print(
            "The service matched none of the ride to a road, so nothing was checked.",
            file=sys.stderr,
        )
        return 2
    settings = {
        "threshold_mph": args.threshold_mph,
        "min_distance_metres": args.min_distance_m,
        "window_seconds": args.window_s,
    }
    print(format_report(result, **settings))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result_json(result, **settings), handle, indent=2)
            handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
