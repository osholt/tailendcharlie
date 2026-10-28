#!/usr/bin/env python3
"""Bounded OCPI collection and viewport service, for the routing host (Refs #971).

No provider request is caused by a viewport query. The scheduler makes one page
request at a time, spaces requests per origin, and commits each page separately.
Incomplete sweeps remain explicitly partial; only a completed sweep deletes rows.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import threading
import time
import tomllib
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from urllib.request import Request, build_opener

from check_feeds import NoRedirect, headers_for, safe_url

MAX_BYTES = 2 * 1024 * 1024
MAX_ROWS = 20_000
MAX_PAGES = 200
PAGE_SIZE = 100
CONNECTORS = {"IEC_62196_T2": 1, "IEC_62196_T2_COMBO": 2, "CHADEMO": 4, "DOMESTIC_G": 8}
STATUSES = {"AVAILABLE", "CHARGING", "RESERVED", "BLOCKED", "INOPERATIVE", "OUTOFORDER"}


def number(value):
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


def timestamp(value):
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return result.timestamp() if result.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def text(value, limit=160):
    return value[:limit] if isinstance(value, str) else ""


def identity(row):
    ident = row.get("id")
    if not isinstance(ident, (str, int)) or isinstance(ident, bool):
        return ""
    return (
        ":".join(str(row.get(k, "")) for k in ("country_code", "party_id")) + ":" + str(ident)[:160]
    )


def simple_tariff(row, now):
    """Only an unconditional GBP ENERGY price with explicit VAT is safe to quote.

    Time/session fees, varying restrictions, missing VAT and competing prices are
    not flattened into a deceptively simple p/kWh figure.
    """
    if row.get("currency") != "GBP":
        return None
    start, end = timestamp(row.get("start_date_time")), timestamp(row.get("end_date_time"))
    if (start is not None and start > now) or (end is not None and end <= now):
        return None
    elements = row.get("elements")
    if not isinstance(elements, list) or len(elements) != 1:
        return None
    element = elements[0]
    if not isinstance(element, dict) or element.get("restrictions"):
        return None
    components = element.get("price_components", [])
    if (
        not isinstance(components, list)
        or len(components) != 1
        or not isinstance(components[0], dict)
    ):
        return None
    part = components[0]
    price, vat = number(part.get("price")), number(part.get("vat"))
    if part.get("type") != "ENERGY" or price is None or vat is None:
        return None
    if not 0 <= price <= 10 or not 0 <= vat <= 100:
        return None
    return round(price * (1 + vat / 100) * 100, 3)


def embedded_price(conn, refs, location, now):
    """Keep a connector-local price; never let embedded IDs price other connectors."""
    value = conn.get("tariffs")
    if isinstance(value, list):
        value = value[0] if len(value) == 1 else None
    if not isinstance(value, dict):
        return None
    ident = value.get("id")
    if not isinstance(ident, str) or not ident or (refs and refs != [ident]):
        return None
    for key in ("country_code", "party_id"):
        if key in value and value[key] != location.get(key):
            return None
    amount = simple_tariff(value, now)
    if amount is None:
        return None
    return [amount, now, timestamp(value.get("end_date_time"))]


def normalize(row, source, now):
    coords = row.get("coordinates")
    if not isinstance(coords, dict) or not identity(row) or row.get("publish") is False:
        return None
    lat, lon = number(coords.get("latitude")), number(coords.get("longitude"))
    # UK register; explicit country avoids showing a platform's global network.
    if row.get("country") not in {"GBR", "GB", "UK"}:
        return None
    if lat is None or lon is None or not 49 <= lat <= 61 or not -9 <= lon <= 3:
        return None
    evses = row.get("evses")
    if not isinstance(evses, list) or len(evses) > 500:
        return None
    connectors = []
    for evse in evses:
        if not isinstance(evse, dict) or evse.get("status") == "REMOVED":
            continue
        for conn in evse.get("connectors", [])[:50]:
            if not isinstance(conn, dict):
                continue
            refs = conn.get("tariff_ids", [])
            if not refs and isinstance(conn.get("tariff_id"), str):
                refs = [conn["tariff_id"]]
            if not isinstance(refs, list):
                refs = []
            watts = number(conn.get("max_electric_power"))
            connectors.append(
                {
                    "type": CONNECTORS.get(conn.get("standard"), 0),
                    "status": evse.get("status") if evse.get("status") in STATUSES else "UNKNOWN",
                    "kilowatts": round(watts / 1000, 1) if watts and 0 < watts <= 2_000_000 else 0,
                    "tariffIds": [text(r) for r in refs[:10] if isinstance(r, str)],
                }
            )
            if "tariffs" in conn:
                # Presence prevents fallback to a stale/separate price when invalid.
                connectors[-1]["embeddedPrice"] = embedded_price(conn, refs, row, now)
    return {
        "id": source + ":" + identity(row),
        "source": source,
        "name": text(row.get("name")) or "Charger",
        "lat": lat,
        "lon": lon,
        "checkedAt": now,
        "updatedAt": timestamp(row.get("last_updated")),
        "countryCode": text(row.get("country_code")),
        "partyId": text(row.get("party_id")),
        "connectors": connectors[:1000],
    }


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.RLock()
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS locations(source TEXT, id TEXT, lat REAL, lon REAL,
                observed REAL, generation REAL, payload TEXT, PRIMARY KEY(source,id));
            CREATE INDEX IF NOT EXISTS bounds ON locations(lat,lon);
            CREATE TABLE IF NOT EXISTS tariffs(source TEXT, id TEXT, observed REAL,
                generation REAL, amount REAL, expires REAL, PRIMARY KEY(source,id));
            CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, name TEXT, checked REAL,
                outcome TEXT, complete INTEGER DEFAULT 0);
        """)

    def outcome(self, feed, status, now):
        with self.lock, self.db:
            self.db.execute(
                "INSERT INTO sources(id,name,checked,outcome) VALUES(?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET outcome=excluded.outcome",
                (feed["id"], feed["name"], None, status),
            )

    def ingest(self, feed, kind, rows, generation, now, complete):
        if kind not in {"locations", "tariffs"}:
            raise ValueError("Unsupported collection module")
        source = feed["id"]
        with self.lock, self.db:
            for row in rows:
                if not isinstance(row, dict):
                    continue
                if kind == "locations":
                    value = normalize(row, source, now)
                    if value:
                        self.db.execute(
                            "INSERT OR REPLACE INTO locations VALUES(?,?,?,?,?,?,?)",
                            (
                                source,
                                value["id"],
                                value["lat"],
                                value["lon"],
                                now,
                                generation,
                                json.dumps(value, allow_nan=False),
                            ),
                        )
                else:
                    ident = identity(row)
                    if ident:
                        self.db.execute(
                            "INSERT OR REPLACE INTO tariffs VALUES(?,?,?,?,?,?)",
                            (
                                source,
                                ident,
                                now,
                                generation,
                                simple_tariff(row, now),
                                timestamp(row.get("end_date_time")),
                            ),
                        )
            # Bound persistence even when a provider keeps returning novel IDs.
            self.db.execute(
                f"DELETE FROM {kind} WHERE source=? AND id NOT IN "  # noqa: S608 - allowlisted table
                f"(SELECT id FROM {kind} WHERE source=? ORDER BY observed DESC,id LIMIT ?)",
                (source, source, MAX_ROWS),
            )
            self.db.execute(
                f"DELETE FROM {kind} WHERE observed < ?",  # noqa: S608 - allowlisted table
                (now - 172800,),
            )
            if complete:
                self.db.execute(
                    f"DELETE FROM {kind} WHERE source=? AND generation<>?",  # noqa: S608 - allowlisted table
                    (source, generation),
                )
            if kind == "locations":
                self.db.execute(
                    "INSERT OR REPLACE INTO sources VALUES(?,?,?,?,?)",
                    (source, feed["name"], now, "ok", int(complete)),
                )

    def viewport(self, west, south, east, north, now):
        values = [west, south, east, north]
        if not all(math.isfinite(v) for v in values) or not (
            -180 <= west < east <= 180
            and -90 <= south < north <= 90
            and east - west <= 0.8
            and north - south <= 0.5
        ):
            raise ValueError("Invalid viewport")
        with self.lock:
            sources = [
                {
                    "id": r[0],
                    "name": r[1],
                    "checkedAt": r[2],
                    "outcome": r[3],
                    "complete": bool(r[4]),
                    "attribution": "Charging data: " + r[1],
                }
                for r in self.db.execute("SELECT * FROM sources ORDER BY id")
            ]
            rows = self.db.execute(
                "SELECT payload FROM locations WHERE lat BETWEEN ? AND ? "
                "AND lon BETWEEN ? AND ? AND observed >= ? ORDER BY id LIMIT 301",
                (south, north, west, east, now - 172800),
            ).fetchall()
            locations = []
            for (payload,) in rows[:300]:
                loc = json.loads(payload)
                for conn in loc["connectors"]:
                    refs = conn.pop("tariffIds")
                    if "embeddedPrice" in conn:
                        price = conn.pop("embeddedPrice")
                    else:
                        # Multiple tariffs can represent contracts or conditional pricing.
                        if len(refs) != 1:
                            continue
                        key = loc["countryCode"] + ":" + loc["partyId"] + ":" + refs[0]
                        price = self.db.execute(
                            "SELECT amount,observed,expires FROM tariffs WHERE source=? AND id=?",
                            (loc["source"], key),
                        ).fetchone()
                    if (
                        price
                        and price[0] is not None
                        and now - price[1] <= 86400
                        and (price[2] is None or price[2] > now)
                    ):
                        conn["pencePerKwh"] = price[0]
                        conn["priceCheckedAt"] = price[1]
                loc.pop("countryCode")
                loc.pop("partyId")
                locations.append(loc)
        return {
            "schemaVersion": 1,
            "generatedAt": now,
            "sources": sources,
            "locations": locations,
            "truncated": len(rows) > 300,
        }


RESPONSE_SHAPES = {"ocpi", "array", "locations-key"}


def rows_from(body, shape):
    """The record list for a response shape, or None when the body does not match it.

    "ocpi" is the standard envelope; "array" is a bare JSON list of records;
    "locations-key" is an object whose "locations" member is the list.
    """
    if shape == "array":
        return body if isinstance(body, list) else None
    if not isinstance(body, dict):
        return None
    if shape == "locations-key":
        rows = body.get("locations")
        return rows if isinstance(rows, list) else None
    if body.get("status_code", 1000) != 1000:
        return None
    return body.get("data")


def fetch_page(url, headers, shape="ocpi"):
    """No redirects, compressed bodies, body/error logging, or uncontrolled reads."""
    request = Request(url, headers=headers)  # noqa: S310 - configured HTTPS origins only
    try:
        with build_opener(NoRedirect()).open(request, timeout=20) as response:
            if response.headers.get("Content-Encoding", "identity") != "identity":
                return 0, None, None
            length = response.headers.get("Content-Length", "")
            if length.isdigit() and int(length) > MAX_BYTES:
                return 0, None, None
            data = bytearray()
            start = time.monotonic()
            while len(data) < MAX_BYTES and time.monotonic() - start < 20:
                chunk = response.read1(min(8192, MAX_BYTES - len(data)))
                if not chunk:
                    rows = rows_from(json.loads(data), shape)
                    if rows is None:
                        return 0, None, None
                    total = response.headers.get("X-Total-Count", "")
                    return 200, rows, int(total) if total.isdigit() else None
                data.extend(chunk)
    except HTTPError as exc:
        code = exc.code
        exc.close()
        return code, None, None
    except (OSError, ValueError, RecursionError):
        pass
    return 0, None, None


class Collector:
    def __init__(self, store, feeds, profiles, environ=None, fetch=fetch_page):
        self.store, self.fetch = store, fetch
        self.environ = os.environ if environ is None else environ
        self.feeds = {f["id"]: f for f in feeds}
        self.jobs = []
        self.origin_due = {}
        for profile in profiles:
            feed = self.feeds[profile["id"]]
            for kind in ("locations", "tariffs"):
                url = feed.get(kind + "_url", "")
                if not url:
                    continue
                if not safe_url(url):
                    raise ValueError("Unsafe configured feed URL")
                self.jobs.append(
                    dict(
                        feed=feed,
                        profile=profile,
                        kind=kind,
                        url=url,
                        offset=0,
                        pages=0,
                        due=0,
                        generation=0,
                    )
                )

    def step(self, now):
        for job in sorted(self.jobs, key=lambda j: j["due"]):
            origin = urlsplit(job["url"]).netloc
            if job["due"] > now or self.origin_due.get(origin, 0) > now:
                continue
            f, p = job["feed"], job["profile"]
            if f["auth"] != "none" and not self.environ.get(f["credential_env"]):
                self.store.outcome(f, "credentials-missing", now)
                job["due"] = now + 3600
                continue
            try:
                headers = headers_for(f, self.environ)
            except ValueError:
                self.store.outcome(f, "credential-configuration", now)
                job["due"] = now + 3600
                continue
            gap = max(31, p.get("request_interval_seconds", 125))
            self.origin_due[origin] = now + gap
            job["due"] = now + gap
            if job["offset"] == 0:
                job["generation"] = now
            shape = f.get("response_shape", "ocpi")
            if shape not in RESPONSE_SHAPES:
                raise ValueError("Unknown response shape")
            # An unpaginated feed returns its whole network in one bounded body
            # (MAX_BYTES), so one response is the complete sweep.
            unpaged = f.get("pagination") == "none"
            if unpaged:
                url, limit = job["url"], MAX_ROWS
            else:
                param = f.get("page_size_parameter", "limit")
                if param not in {"limit", "per_page"}:
                    raise ValueError("Unknown pagination parameter")
                query = {param: PAGE_SIZE, "offset": job["offset"]}
                if param == "per_page":
                    query = {param: PAGE_SIZE, "page": job["pages"] + 1}
                url = urlunsplit(urlsplit(job["url"])._replace(query=urlencode(query)))
                limit = PAGE_SIZE
            status, rows, total = self.fetch(url, headers, shape)
            if (
                status != 200
                or not isinstance(rows, list)
                or len(rows) > limit
                or (not unpaged and not rows and total is not None and job["offset"] < total)
            ):
                self.store.outcome(f, "rate-limited" if status == 429 else "fetch-failed", now)
                if status == 429:
                    self.origin_due[origin] = now + 3600
                # An interrupted sweep restarts; never delete the old complete snapshot.
                job.update(offset=0, pages=0, due=now + max(3600, p.get("refresh_seconds", 600)))
                return True
            # A provider may cap pages below our requested size. Its total takes
            # precedence over a short page (char.gy returns at most 50 rows).
            complete = unpaged or (
                job["offset"] + len(rows) >= total if total is not None else len(rows) < PAGE_SIZE
            )
            self.store.ingest(f, job["kind"], rows, job["generation"], now, complete)
            job["pages"] += 1
            job["offset"] += len(rows)
            if complete or job["pages"] >= MAX_PAGES or job["offset"] >= MAX_ROWS:
                job.update(offset=0, pages=0, due=now + max(300, p.get("refresh_seconds", 600)))
            return True
        return False


def serve(store, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # A viewport is rider-location data.

        def do_GET(self):
            path = urlsplit(self.path)
            if path.path != "/v1/chargers":
                self.send_error(404)
                return
            try:
                args = parse_qs(path.query, max_num_fields=4)
                if set(args) != {"west", "south", "east", "north"} or any(
                    len(v) != 1 for v in args.values()
                ):
                    raise ValueError("Invalid query")
                result = store.viewport(
                    **{k: float(v[0]) for k, v in args.items()}, now=time.time()
                )
                body = json.dumps(result, allow_nan=False).encode()
                if len(body) > MAX_BYTES:
                    self.send_error(503)
                    return
            except (ValueError, TypeError):
                self.send_error(400)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    HTTPServer(("0.0.0.0", port), Handler).serve_forever()  # noqa: S104 - private container network


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--register", type=Path, default=Path(__file__).with_name("feeds.toml"))
    parser.add_argument(
        "--profiles", type=Path, default=Path(__file__).with_name("collection.toml")
    )
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8090)
    args = parser.parse_args()
    store = Store(args.database)
    collector = Collector(
        store,
        tomllib.loads(args.register.read_text())["feed"],
        tomllib.loads(args.profiles.read_text())["collect"],
    )
    threading.Thread(target=serve, args=(store, args.port), daemon=True).start()
    while True:
        try:
            collector.step(time.time())
        except Exception:
            # No exception text: upstream errors and URLs can contain secrets.
            print("Collector page failed; continuing", flush=True)
        time.sleep(1)


if __name__ == "__main__":
    main()
