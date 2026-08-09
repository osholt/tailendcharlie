"""Live smoke test for a freshly deployed relay stack.

Run by `relay-deploy.sh` inside a throwaway container on the host's internal
Docker network, so it exercises the API exactly as the public proxy reaches it
and does not depend on DNS, TLS or the proxy's own configuration.

Environment:
  SMOKE_ORIGIN            http origin of the API on the Docker network
  SMOKE_HOST              Host header to send; the API rejects untrusted names
  SMOKE_EXPECTED_COMMIT   commit the deployed image must report
  SMOKE_WRITE_PLAN        "1" to include the round trip that writes to the
                          database. Pre-production only: production's database
                          is riders' data, not a test fixture.

Exits non-zero on the first failure, with the check that failed named.
"""

import json
import os
import sys
import urllib.error
import urllib.request

ORIGIN = os.environ["SMOKE_ORIGIN"].rstrip("/")
HOST = os.environ["SMOKE_HOST"]
EXPECTED_COMMIT = os.environ["SMOKE_EXPECTED_COMMIT"]
WRITE_PLAN = os.environ.get("SMOKE_WRITE_PLAN") == "1"
TIMEOUT = 15

# Two points a few metres apart on a public road. The plan round trip proves
# the API, the encryption key and PostgreSQL all agree; the content is
# irrelevant beyond passing the same GPX bounds the phone applies.
SMOKE_GPX = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<gpx version="1.1" creator="relay-deploy-smoke">'
    "<trk><trkseg>"
    '<trkpt lat="51.4545" lon="-2.5879"/>'
    '<trkpt lat="51.4546" lon="-2.5878"/>'
    "</trkseg></trk></gpx>"
)


class SmokeFailure(Exception):
    pass


def request(method, path, body=None):
    headers = {"Host": HOST}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    call = urllib.request.Request(  # noqa: S310
        ORIGIN + path, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(call, timeout=TIMEOUT) as response:  # noqa: S310
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise SmokeFailure(f"{method} {path} answered HTTP {error.code}") from error
    except OSError as error:
        raise SmokeFailure(f"{method} {path} could not be reached: {error}") from error
    if not payload:
        return None
    try:
        return json.loads(payload)
    except ValueError as error:
        raise SmokeFailure(f"{method} {path} answered unreadable JSON") from error


def check_liveness():
    document = request("GET", "/health/live")
    if document != {"status": "ok"}:
        raise SmokeFailure(f"unexpected liveness document: {document!r}")


def check_readiness():
    document = request("GET", "/health/ready")
    if not isinstance(document, dict) or document.get("status") != "ready":
        raise SmokeFailure(f"unexpected readiness document: {document!r}")


def check_deployed_commit():
    """The only trustworthy answer to what is running.

    The checkout on disk can disagree with the built image — it did after the
    9 August reboot — so parity is judged on what the image reports, never on
    what `git log` on the box says.
    """
    document = request("GET", "/api/v1/compatibility")
    deployed = document.get("serverBuildCommit")
    if deployed != EXPECTED_COMMIT:
        raise SmokeFailure(f"deployed image reports {deployed!r}, expected {EXPECTED_COMMIT}")
    protocol = document.get("serverProtocol")
    if not isinstance(protocol, int) or protocol < 1:
        raise SmokeFailure(f"invalid server protocol: {protocol!r}")


def check_plan_round_trip():
    created = request("POST", "/api/v1/plans", {"name": "relay-deploy smoke", "gpx": SMOKE_GPX})
    code = created.get("code")
    if not code:
        raise SmokeFailure(f"plan creation returned no code: {created!r}")
    fetched = request("GET", f"/api/v1/plans/{code}")
    if fetched.get("gpx") != SMOKE_GPX:
        raise SmokeFailure(f"plan {code} did not read back the GPX it was given")


def main():
    checks = [
        ("liveness", check_liveness),
        ("readiness", check_readiness),
        ("deployed commit", check_deployed_commit),
    ]
    if WRITE_PLAN:
        checks.append(("plan round trip", check_plan_round_trip))

    for name, check in checks:
        try:
            check()
        except SmokeFailure as failure:
            print(f"smoke: {name}: FAILED: {failure}", file=sys.stderr)
            return 1
        print(f"smoke: {name}: ok")
    print(f"smoke: {ORIGIN} is serving {EXPECTED_COMMIT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
