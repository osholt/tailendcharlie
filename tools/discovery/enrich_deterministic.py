"""Derive rider-facing facts for each discovery candidate from the OSM extract.

Everything this script produces is reproducible from the checksummed extract, so it
belongs in the generator rather than in the hand-written editorial overlay. The
split matters: regenerating the catalogue must never destroy hand-researched prose,
and must always refresh the tag-derived facts.

Fields produced per candidate:

  speedLimit          the mapped limit, with provenance (see below)
  averageSpeedCheck   whether an OSM enforcement=average_speed relation covers it
  fixedSpeedCameras   count of highway=speed_camera nodes near the geometry
  locality            nearest settlement, for disambiguating names
  roadRefs/roadClass  for naming and for the ride-planner description

Provenance on the speed limit is not decoration. #145 was caused by trusting a
Valhalla `speed_type` that never held the expected value, and the honest states here
are the same defence: a limit is `tagged` only when OSM actually says so.
"""

import json
import math
import os
import re
from collections import Counter

OUT = os.environ.get("DISCOVERY_WORK_DIR", "/private/tmp/discovery-out")

# osmium's OPL format escapes a character as a percent sign, its hex codepoint, and
# a *terminating* percent sign: a space is `%20%`, not `%20`. Decoding it as bare
# `%20` silently leaves the terminator behind, turning `40 mph` into `40 %mph` — and
# every speed limit then fails to parse while looking almost right in a log.
_ESCAPE = re.compile(r"%([0-9a-fA-F]+)%")


def unescape(text):
    return _ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), text)


def parse_opl(path):
    """Yield (type, id, tags, lon, lat, members) for each OPL line."""
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        kind = line[0]
        fields = line.split(" ")
        tags, lon, lat, members = {}, None, None, []
        for field in fields[1:]:
            if len(field) < 2:
                continue
            code, rest = field[0], field[1:]
            if code == "T":
                for pair in rest.split(","):
                    if "=" in pair:
                        key, value = pair.split("=", 1)
                        tags[unescape(key)] = unescape(value)
            elif code == "x":
                lon = float(rest)
            elif code == "y":
                lat = float(rest)
            elif code == "M":
                members = rest.split(",")
        yield kind, fields[0][1:], tags, lon, lat, members


# --- speed limits -----------------------------------------------------------

# Great Britain national speed limits, by carriageway type. Only used to resolve an
# explicit maxspeed:type tag — never to guess at an untagged road, which is the
# difference between reporting a fact and inventing one.
NSL = {
    "GB:nsl_single": "60 mph",
    "GB:nsl_dual": "70 mph",
    "GB:motorway": "70 mph",
    "GB:nsl_restricted": "30 mph",
    "GB:zone20": "20 mph",
    "GB:zone30": "30 mph",
    "GB:zone40": "40 mph",
}


def normalise_speed(raw):
    """Return a canonical 'NN mph' string, or None if it is not a plain limit."""
    if not raw:
        return None
    value = raw.strip()
    if value.endswith(" mph"):
        head = value[:-4].strip()
        return f"{head} mph" if head.isdigit() else None
    if value.isdigit():
        # A bare number in OSM means km/h. Convert so the catalogue is one unit.
        return f"{round(int(value) / 1.609344 / 5) * 5} mph"
    return None


def speed_limit_for(ways):
    """Aggregate the mapped limit across a candidate's member ways."""
    tagged, inferred = Counter(), Counter()
    for tags in ways:
        direct = normalise_speed(tags.get("maxspeed"))
        if direct:
            tagged[direct] += 1
            continue
        implied = NSL.get(tags.get("maxspeed:type", ""))
        if implied:
            inferred[implied] += 1

    if tagged:
        values, provenance = tagged, "tagged"
        # A candidate spanning both tagged and inferred sections is still tagged
        # overall, but the inferred sections should not vanish from the range.
        values = values + inferred
    elif inferred:
        values, provenance = inferred, "inferred-from-maxspeed-type"
    else:
        return {
            "value": None,
            "provenance": "unknown",
            "note": "OpenStreetMap does not record a limit for this road.",
        }

    ordered = sorted(values, key=lambda v: int(v.split()[0]))
    predominant = values.most_common(1)[0][0]
    result = {
        "value": predominant,
        "provenance": provenance,
        "mixed": len(ordered) > 1,
    }
    if len(ordered) > 1:
        result["range"] = [ordered[0], ordered[-1]]
    return result


# --- geometry helpers -------------------------------------------------------

EARTH_R = 6371008.8


def haversine(lon1, lat1, lon2, lat2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


def coordinates_of(feature):
    """Flatten a candidate's geometry to a list of (lon, lat)."""
    geometry = feature["geometry"]
    kind = geometry["type"]
    if kind == "Point":
        return [tuple(geometry["coordinates"])]
    if kind == "LineString":
        return [tuple(c) for c in geometry["coordinates"]]
    if kind == "MultiLineString":
        return [tuple(c) for line in geometry["coordinates"] for c in line]
    return []


class Grid:
    """Coarse lon/lat bucket index. Plenty for nearest-settlement at this scale."""

    CELL = 0.1  # degrees, ~11 km of latitude

    def __init__(self, points):
        self.cells = {}
        for point in points:
            self.cells.setdefault(self._key(point[0], point[1]), []).append(point)

    def _key(self, lon, lat):
        return (int(lon / self.CELL), int(lat / self.CELL))

    def nearest(self, lon, lat, max_rings=4):
        cx, cy = self._key(lon, lat)
        best, best_distance = None, None
        for ring in range(max_rings + 1):
            for dx in range(-ring, ring + 1):
                for dy in range(-ring, ring + 1):
                    # Only the newly reachable ring, not the filled square.
                    if ring and max(abs(dx), abs(dy)) != ring:
                        continue
                    for point in self.cells.get((cx + dx, cy + dy), ()):
                        distance = haversine(lon, lat, point[0], point[1])
                        if best_distance is None or distance < best_distance:
                            best, best_distance = point, distance
            if best is not None:
                # Found something in this ring; one more ring guards against a
                # closer point just over a cell boundary.
                if ring + 1 <= max_rings:
                    ring += 1
                break
        return best, best_distance

    def within(self, lon, lat, radius):
        cx, cy = self._key(lon, lat)
        span = int(radius / (self.CELL * 111000)) + 1
        found = []
        for dx in range(-span, span + 1):
            for dy in range(-span, span + 1):
                for point in self.cells.get((cx + dx, cy + dy), ()):
                    if haversine(lon, lat, point[0], point[1]) <= radius:
                        found.append(point)
        return found


def main():
    catalogue = json.load(open(f"{OUT}/discovery-catalogue.geojson"))
    features = catalogue["features"]

    # Parsed here with the same decoder as everything else, rather than read from a
    # side file written by a second parser.
    way_tags = {}
    for kind, oid, tags, _, _, _ in parse_opl(f"{OUT}/candidate-objects.opl"):
        way_tags[f"{'way' if kind == 'w' else 'node'}/{oid}"] = tags
    print(f"candidate objects {len(way_tags)}")

    # Average speed enforcement: OSM models these as type=enforcement relations
    # with the covered carriageway as `section` members, so this is an exact id
    # join rather than a spatial guess.
    average_speed_ways = {}
    for kind, oid, tags, _, _, members in parse_opl(f"{OUT}/enforcement.opl"):
        if kind != "r" or tags.get("enforcement") != "average_speed":
            continue
        detail = {
            "relation": f"relation/{oid}",
            "enforcedLimit": normalise_speed(tags.get("maxspeed")),
            "description": tags.get("description") or tags.get("note"),
        }
        for member in members:
            if member.startswith("w"):
                average_speed_ways[f"way/{member[1:].split('@')[0]}"] = detail

    cameras = Grid(
        [
            (lon, lat, tags)
            for kind, _, tags, lon, lat, _ in parse_opl(f"{OUT}/enforcement.opl")
            if kind == "n" and lon is not None and tags.get("highway") == "speed_camera"
        ]
    )

    settlements, peaks = [], []
    for kind, _, tags, lon, lat, _ in parse_opl(f"{OUT}/places.opl"):
        if kind != "n" or lon is None or not tags.get("name"):
            continue
        if tags.get("place"):
            settlements.append((lon, lat, tags))
        elif tags.get("natural") == "peak":
            peaks.append((lon, lat, tags))
    settlement_grid, peak_grid = Grid(settlements), Grid(peaks)
    print(f"settlements {len(settlements)}  peaks {len(peaks)}")

    enrichment = {}
    stats = Counter()
    for feature in features:
        props = feature["properties"]
        ids = props.get("sourceFeatureIds") or [props.get("sourceFeatureId")]
        ids = [i for i in ids if i]
        ways = [way_tags[i] for i in ids if i in way_tags]

        limit = speed_limit_for(ways)
        stats[f"speed:{limit['provenance']}"] += 1

        average = next((average_speed_ways[i] for i in ids if i in average_speed_ways), None)
        if average:
            stats["average-speed-check"] += 1

        points = coordinates_of(feature)
        midpoint = points[len(points) // 2] if points else None
        nearby_cameras = []
        if midpoint:
            # Sample rather than test every vertex; candidates are long and the
            # vertices are dense, so this is the same answer for far less work.
            step = max(1, len(points) // 40)
            seen = set()
            for lon, lat in points[::step]:
                for camera in cameras.within(lon, lat, 250):
                    key = (camera[0], camera[1])
                    if key not in seen:
                        seen.add(key)
                        nearby_cameras.append(camera[2])
        if nearby_cameras:
            stats["fixed-cameras"] += 1

        record = {
            "speedLimit": limit,
            "averageSpeedCheck": average or {"present": False},
            "fixedSpeedCameras": len(nearby_cameras),
            "roadRefs": sorted({t["ref"] for t in ways if t.get("ref")}),
            "roadNames": sorted({t["name"] for t in ways if t.get("name")}),
            "roadClasses": sorted({t["highway"] for t in ways if t.get("highway")}),
            "surfaces": sorted({t["surface"] for t in ways if t.get("surface")}),
            "wayCount": len(ways),
        }
        if average:
            record["averageSpeedCheck"]["present"] = True

        if midpoint:
            place, distance = settlement_grid.nearest(*midpoint)
            if place:
                record["locality"] = {
                    "name": place[2]["name"],
                    "kind": place[2].get("place"),
                    "distanceMetres": round(distance),
                }
            if props.get("category") == "mountain_pass":
                peak, peak_distance = peak_grid.nearest(*midpoint)
                if peak and peak_distance < 5000:
                    record["nearestPeak"] = {
                        "name": peak[2]["name"],
                        "elevation": peak[2].get("ele"),
                        "distanceMetres": round(peak_distance),
                    }

        enrichment[props["id"]] = record

    json.dump(enrichment, open(f"{OUT}/enrichment-deterministic.json", "w"), indent=1)
    print(f"\nwrote enrichment for {len(enrichment)} candidates")
    for key in sorted(stats):
        print(f"  {key:36s} {stats[key]}")


if __name__ == "__main__":
    main()
