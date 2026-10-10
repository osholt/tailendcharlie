"""Smoke test for the self-hosted routing and geocoding service (#917).

Run by routing-data-refresh.sh and routing-deploy.sh inside a throwaway
container (the Valhalla image, which carries Python), so the host needs nothing
but Docker. Three independent modes, selected by which origins are set:

  SMOKE_VALHALLA_ORIGIN   http origin of a Valhalla engine on a Docker network:
                          a candidate build before promotion, or the serving one
  SMOKE_PHOTON_ORIGIN     the same for Photon
  SMOKE_PUBLIC_ORIGIN     https origin of the public edge, which adds the Caddy
                          checks: TLS, the client gate, CORS and the health
                          routes. Needs SMOKE_CLIENT_ID and SMOKE_PLANNER_ORIGIN.
  SMOKE_COUNTRIES         countries the data must cover, default GB,IE,IM,FR.
                          Keep it in step with the extracts the build uses.

Every check is a read, so it is safe against production at any time. The places
below are public city-centre landmarks chosen to prove each country's data is in
the build; they are test inputs, not anything the app treats specially.

Exits non-zero on the first failure, naming the check.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30

# Short drives inside each country the build must cover, and a pair of points on
# one main road in each, for the matching services.
ROUTES = {
    "GB": ((51.50809, -0.12806), (51.51385, -0.09835)),
    "IE": ((53.34724, -6.25913), (53.34880, -6.27820)),
    "IM": ((54.15040, -4.48190), (54.16900, -4.49000)),
    "FR": ((48.85296, 2.34990), (48.87380, 2.29504)),
}
ROADS = {
    "GB": ((51.50500, -0.12650), (51.50350, -0.12630)),
    "IE": ((53.34980, -6.26030), (53.35180, -6.26100)),
    "FR": ((48.86980, 2.30760), (48.87100, 2.30360)),
}
PLACES = {
    "GB": "London",
    "IE": "Dublin",
    "IM": "Douglas, Isle of Man",
    "FR": "Paris",
}
REQUIRED_ACTIONS = {"route", "trace_route", "trace_attributes", "locate"}
COUNTRIES = [
    code.strip().upper()
    for code in (os.environ.get("SMOKE_COUNTRIES") or "GB,IE,IM,FR").split(",")
    if code.strip()
]


class SmokeFailure(Exception):
    pass


def call(url, body=None, headers=None, expect=200):
    """Returns (status, headers, decoded JSON or None)."""
    request_headers = {"Accept": "application/json", **(headers or {})}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(  # noqa: S310
        url, data=data, headers=request_headers, method="POST" if data else "GET"
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310
            status, response_headers, payload = response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        status, response_headers, payload = error.code, error.headers, error.read()
    except OSError as error:
        raise SmokeFailure(f"{url} could not be reached: {error}") from error
    if expect is not None and status != expect:
        raise SmokeFailure(f"{url} answered HTTP {status}, expected {expect}")
    try:
        document = json.loads(payload) if payload else None
    except ValueError as error:
        raise SmokeFailure(f"{url} answered unreadable JSON") from error
    return status, response_headers, document


def location(point):
    return {"lat": point[0], "lon": point[1]}


# --- Valhalla ---------------------------------------------------------------


def valhalla_checks(origin, headers=None):
    def post(action, body):
        return call(f"{origin}/{action}", body, headers)[2]

    def status():
        document = call(f"{origin}/status", headers=headers)[2]
        if not isinstance(document, dict) or not document.get("version"):
            raise SmokeFailure(f"status reports no version: {document!r}")
        missing = REQUIRED_ACTIONS - set(document.get("available_actions") or [])
        if missing:
            raise SmokeFailure(f"actions not served: {sorted(missing)}")

    def routes():
        for country in COUNTRIES:
            start, end = ROUTES[country]
            for costing in ("motorcycle", "auto"):
                document = post(
                    "route",
                    {"locations": [location(start), location(end)], "costing": costing},
                )
                trip = (document or {}).get("trip") or {}
                length = (trip.get("summary") or {}).get("length")
                if trip.get("status") != 0 or not length:
                    raise SmokeFailure(f"{costing} route in {country} failed: {document!r}")

    def locate():
        start = ROUTES[COUNTRIES[0]][0]
        document = post("locate", {"locations": [location(start)], "costing": "motorcycle"})
        if not isinstance(document, list) or not document or not document[0].get("edges"):
            raise SmokeFailure(f"locate found no road: {document!r}")

    def matching():
        speed_limits = 0
        sampled = [country for country in COUNTRIES if country in ROADS]
        for country in sampled:
            start, end = ROADS[country]
            document = post(
                "trace_attributes",
                {
                    "shape": [location(start), location(end)],
                    "costing": "motorcycle",
                    "shape_match": "map_snap",
                    "trace_options": {"gps_accuracy": 15, "search_radius": 30},
                },
            )
            edges = (document or {}).get("edges") or []
            countries = {
                admin.get("country_code") for admin in (document or {}).get("admins") or []
            }
            if not edges:
                raise SmokeFailure(f"trace_attributes in {country} matched no road")
            # Country codes come from the admin database. Without it the app's
            # speed-limit sign cannot tell a UK limit from a French one.
            if country not in countries:
                raise SmokeFailure(
                    f"trace_attributes in {country} reports countries {sorted(countries)}"
                )
            speed_limits += sum(1 for edge in edges if isinstance(edge.get("speed_limit"), int))
            document = post(
                "trace_route",
                {"shape": [location(start), location(end)], "costing": "motorcycle"},
            )
            if ((document or {}).get("trip") or {}).get("status") != 0:
                raise SmokeFailure(f"trace_route in {country} failed: {document!r}")
        if sampled and speed_limits == 0:
            raise SmokeFailure("no matched road carried a speed limit; the build lost maxspeed")

    return [
        ("valhalla status", status),
        (f"valhalla routes (motorcycle and auto, {'/'.join(COUNTRIES)})", routes),
        ("valhalla locate", locate),
        ("valhalla trace_attributes and trace_route", matching),
    ]


# --- Photon -----------------------------------------------------------------


def photon_checks(origin, headers=None):
    def status():
        document = call(f"{origin}/status", headers=headers)[2]
        if not isinstance(document, dict) or str(document.get("status")).lower() != "ok":
            raise SmokeFailure(f"unexpected status document: {document!r}")

    def search():
        for country in COUNTRIES:
            query = PLACES[country]
            url = f"{origin}/api?" + urllib.parse.urlencode({"q": query, "limit": 5})
            document = call(url, headers=headers)[2]
            found = {
                (feature.get("properties") or {}).get("countrycode")
                for feature in (document or {}).get("features") or []
            }
            if country not in found:
                raise SmokeFailure(
                    f"search for {query!r} found countries {sorted(found)}, not {country}"
                )

    return [("photon status", status), (f"photon search {'/'.join(COUNTRIES)}", search)]


# --- Public edge ------------------------------------------------------------


def public_checks(origin, client_id, planner_origin):
    identified = {"X-Client-Id": client_id}

    def health():
        document = call(f"{origin}/health")[2]
        if document != {"status": "ok"}:
            raise SmokeFailure(f"unexpected edge health: {document!r}")
        call(f"{origin}/health/valhalla")
        call(f"{origin}/health/photon")

    def client_gate():
        # An anonymous caller is refused before it reaches an engine.
        call(f"{origin}/valhalla/status", expect=403)
        call(f"{origin}/photon/status", expect=403)
        call(f"{origin}/valhalla/status", headers=identified)
        call(f"{origin}/valhalla/isochrone", headers=identified, expect=404)

    def planner_cors():
        _, headers, _ = call(f"{origin}/valhalla/status", headers={"Origin": planner_origin})
        allowed = headers.get("Access-Control-Allow-Origin")
        if allowed != planner_origin:
            raise SmokeFailure(f"planner origin answered Access-Control-Allow-Origin {allowed!r}")
        call(f"{origin}/valhalla/status", headers={"Origin": "https://example.invalid"}, expect=403)

    return [
        ("edge health routes", health),
        ("client identification gate", client_gate),
        ("web planner CORS", planner_cors),
        *valhalla_checks(f"{origin}/valhalla", identified),
        *photon_checks(f"{origin}/photon", identified),
    ]


def main():
    unknown = sorted(set(COUNTRIES) - set(ROUTES))
    if unknown or not COUNTRIES:
        print(f"smoke: no test places for countries {unknown or COUNTRIES}", file=sys.stderr)
        return 2
    checks = []
    if valhalla := os.environ.get("SMOKE_VALHALLA_ORIGIN"):
        checks += valhalla_checks(valhalla.rstrip("/"))
    if photon := os.environ.get("SMOKE_PHOTON_ORIGIN"):
        checks += photon_checks(photon.rstrip("/"))
    if public := os.environ.get("SMOKE_PUBLIC_ORIGIN"):
        checks += public_checks(
            public.rstrip("/"),
            os.environ["SMOKE_CLIENT_ID"],
            os.environ["SMOKE_PLANNER_ORIGIN"],
        )
    if not checks:
        print("smoke: no origin given", file=sys.stderr)
        return 2
    for name, check in checks:
        try:
            check()
        except SmokeFailure as failure:
            print(f"smoke: {name}: FAILED: {failure}", file=sys.stderr)
            return 1
        print(f"smoke: {name}: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
