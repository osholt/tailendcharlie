#!/usr/bin/env python3
"""Bounded, read-only spot checks of published charge-point feeds (Python 3.12)."""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import re
import time
import tomllib
from collections import Counter
from datetime import datetime
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zoneinfo import ZoneInfo

USER_AGENT = "TailEndCharlie-feed-register/1.0 (+https://tailendcharlie.app)"
TIMEOUT = 20
# Deliberately much smaller than the task's 2 MB ceiling. No response is saved.
MAX_BYTES = 64 * 1024
OUTCOMES = (
    "open-and-working",
    "needs-key",
    "basic-auth",
    "published-but-failing",
    "not-published",
    "published-not-sampled",
)
REGISTER = Path(__file__).with_name("feeds.toml")


class NoRedirect(HTTPRedirectHandler):
    """A redirect consumes a request: report it, never follow or forward secrets."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def safe_url(url: str) -> bool:
    """Only reviewed HTTPS URLs; credentials never belong in a URL."""
    try:
        parts = urlsplit(url)
        return bool(
            parts.scheme == "https"
            and parts.hostname
            and not parts.username
            and not parts.password
            and not parts.fragment
            and not parts.query
        )
    except ValueError:
        return False


def headers_for(feed: dict, environ: dict) -> dict:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        "Accept-Encoding": "identity",
    }
    env_name = feed["credential_env"]
    # No credential discovery, files, login, OAuth exchange or registration.
    secret = environ.get(env_name, "") if env_name else ""
    if not secret or feed["auth"] in {"none", "unknown"}:
        return headers
    if "\r" in secret or "\n" in secret:
        raise ValueError("invalid credential")
    if feed["auth"] == "basic":
        if ":" not in secret:
            raise ValueError("invalid credential")
        headers["Authorization"] = "Basic " + base64.b64encode(secret.encode()).decode("ascii")
    else:
        header = feed.get("auth_header", "")
        scheme = feed.get("auth_scheme", "")
        if header not in {"Authorization", "ec-subscription-key", "X-API-Key"}:
            raise ValueError("unconfigured credential header")
        if scheme not in {"", "Token", "Bearer"}:
            raise ValueError("unconfigured credential scheme")
        headers[header] = f"{scheme} {secret}" if scheme else secret
    return headers


def request_json(url: str, headers: dict, opener=None) -> tuple[dict, object]:
    """Return allowlisted metadata and transient JSON; never error/body text."""
    opener = opener or build_opener(NoRedirect())
    meta = {"http": 0, "result": "network-error", "total_count": -1, "link": False}
    started = time.monotonic()
    try:
        # probe validates HTTPS targets before credentials; NoRedirect blocks redirects.
        request = Request(url, headers=headers)  # noqa: S310
        with opener.open(request, timeout=TIMEOUT) as response:
            meta["http"] = response.status
            total = response.headers.get("X-Total-Count", "")
            if re.fullmatch(r"[0-9]{1,9}", total):
                meta["total_count"] = int(total)
            meta["link"] = bool(response.headers.get("Link"))
            if response.headers.get("Content-Encoding", "identity") != "identity":
                meta["result"] = "encoded-body-skipped"
                return meta, None
            length = response.headers.get("Content-Length", "")
            if length.isdigit() and int(length) > MAX_BYTES:
                meta["result"] = "oversize-body-skipped"
                return meta, None
            body = bytearray()
            while len(body) < MAX_BYTES:
                if time.monotonic() - started >= TIMEOUT:
                    meta["result"] = "timeout"
                    return meta, None
                chunk = response.read1(min(8192, MAX_BYTES - len(body)))
                if not chunk:
                    break
                body.extend(chunk)
            else:
                meta["result"] = "body-limit"
                return meta, None
            try:
                data = json.loads(body)
            except (ValueError, UnicodeError, RecursionError):
                meta["result"] = "invalid-json"
                return meta, None
            if isinstance(data, dict) and data.get("status_code", 1000) != 1000:
                meta["result"] = "ocpi-error"
                return meta, None
            meta["result"] = "json"
            return meta, data
    except HTTPError as exc:
        meta.update(http=exc.code, result="http-error")
        exc.close()
    except TimeoutError:
        meta["result"] = "timeout"
    except (URLError, OSError, ValueError, HTTPException):
        pass
    return meta, None


def items(data: object) -> list:
    if isinstance(data, dict):
        data = data.get("data", data.get("locations", []))
    return data if isinstance(data, list) else []


def sample_features(data: object) -> dict:
    """Presence in one sample is not completeness, accuracy or freshness."""
    rows = items(data)
    result = {"locations": 0, "status": "unknown", "tariffs": "unknown"}
    if len(rows) != 1:
        return result
    location = rows[0]
    if not isinstance(location, dict) or not isinstance(location.get("evses"), list):
        return result
    if not isinstance(location.get("coordinates"), dict) or not location.get("id"):
        return result
    result["locations"] = 1
    evses = [evse for evse in location["evses"] if isinstance(evse, dict)]
    statuses = {
        "AVAILABLE",
        "BLOCKED",
        "CHARGING",
        "INOPERATIVE",
        "OUTOFORDER",
        "PLANNED",
        "REMOVED",
        "RESERVED",
        "UNKNOWN",
    }
    result["status"] = (
        "observed"
        if any(isinstance(e.get("status"), str) and e["status"] in statuses for e in evses)
        else "not-observed"
    )
    connectors = [
        c
        for e in evses
        if isinstance(e.get("connectors"), list)
        for c in e["connectors"]
        if isinstance(c, dict)
    ]
    result["tariffs"] = (
        "references-only"
        if any(c.get("tariff_ids") or c.get("tariff_id") for c in connectors)
        else "not-observed"
    )

    # Only a numeric ENERGY component is evidence of an actual per-kWh price.
    pending = [location]
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            if (
                node.get("type") == "ENERGY"
                and type(node.get("price")) in {int, float}
                and (type(node["price"]) is int or math.isfinite(node["price"]))
                and node["price"] >= 0
            ):
                result["tariffs"] = "observed"
                break
            pending.extend(node.values())
        elif isinstance(node, list):
            pending.extend(node)
    return result


def tariff_features(data: object) -> str:
    """One OCPI tariff with a finite ENERGY price; never imply a Location join."""
    rows = items(data)
    if len(rows) != 1 or not isinstance(rows[0], dict):
        return "unknown"
    tariff = rows[0]
    if not tariff.get("id") or not re.fullmatch(r"[A-Z]{3}", str(tariff.get("currency", ""))):
        return "unknown"
    elements = tariff.get("elements")
    if not isinstance(elements, list):
        return "unknown"
    for element in elements:
        components = element.get("price_components") if isinstance(element, dict) else None
        if not isinstance(components, list):
            continue
        for component in components:
            if not isinstance(component, dict):
                continue
            price = component.get("price")
            if (
                component.get("type") == "ENERGY"
                and type(price) in {int, float}
                and (type(price) is int or math.isfinite(price))
                and price >= 0
            ):
                return "observed"
    return "not-observed"


def probe(feed: dict, environ=None, opener=None, *, tariffs_only=False) -> dict:
    result = {
        "id": feed["id"],
        "checked_on": datetime.now(ZoneInfo("Europe/London")).date().isoformat(),
        "requests": [],
        "versions": [],
        "modules": [],
        "status": "unknown",
        "tariffs": "unknown",
        "outcome": "not-published",
        "reason": "no-published-endpoint",
    }
    if feed.get("probe_skip"):
        result.update(outcome=feed["check_result"], reason=feed["probe_skip"])
        return result
    kinds = ("tariffs",) if tariffs_only else ("versions", "locations")
    urls = [(kind, feed.get(f"{kind}_url", "")) for kind in kinds]
    urls = [(kind, url) for kind, url in urls if url]
    if not urls:
        result.update(
            outcome="published-not-sampled" if tariffs_only else feed["check_result"],
            reason="no-published-endpoint",
        )
        return result
    if any(not safe_url(url) for _, url in urls):
        result.update(outcome="published-not-sampled", reason="unsafe-url")
        return result
    try:
        headers = headers_for(feed, os.environ if environ is None else environ)
    except ValueError:
        result.update(outcome="published-not-sampled", reason="credential-configuration")
        return result
    result["outcome"] = "published-but-failing"
    for kind, url in urls:
        if kind in {"locations", "tariffs"}:
            param = feed.get("page_size_parameter", "limit")
            if param not in {"limit", "per_page", "page_size"}:
                result.update(outcome="published-not-sampled", reason="pagination-configuration")
                break
            parts = urlsplit(url)
            query = [(param, "1")]
            url = urlunsplit(parts._replace(query=urlencode(query)))
        meta, data = request_json(url, headers, opener)
        result["requests"].append({"kind": kind, **meta})
        result["reason"] = meta["result"]
        if meta["http"] in {401, 403}:
            if feed["auth"] == "basic":
                result["outcome"] = "basic-auth"
            elif feed["auth"] in {"token", "emailed-key"}:
                result["outcome"] = "needs-key"
            # A bare 403 is not proof that credentials are required.
            break
        if meta["http"] == 429:
            break  # No retry, even if Retry-After is supplied.
        if kind == "versions":
            result["versions"] = sorted(
                {
                    str(v["version"])
                    for v in items(data)
                    if isinstance(v, dict)
                    and re.fullmatch(r"\d\.\d(?:\.\d)?", str(v.get("version", "")))
                }
            )
            endpoints = (
                data.get("data", {}).get("endpoints", [])
                if isinstance(data, dict) and isinstance(data.get("data"), dict)
                else []
            )
            result["modules"] = sorted(
                {
                    e["identifier"]
                    for e in (endpoints if isinstance(endpoints, list) else [])
                    if isinstance(e, dict)
                    and isinstance(e.get("identifier"), str)
                    and e.get("identifier")
                    in {
                        "locations",
                        "tariffs",
                        "credentials",
                        "sessions",
                        "cdrs",
                        "tokens",
                        "commands",
                        "hubclientinfo",
                        "chargingprofiles",
                    }
                }
            )
        elif kind == "tariffs" and meta["result"] == "json":
            result["tariffs"] = tariff_features(data)
            result.update(
                outcome="published-not-sampled",
                reason="no-per-kwh-price-in-one-tariff",
            )
            if result["tariffs"] == "observed":
                authenticated = any(
                    key in headers for key in ("Authorization", "ec-subscription-key", "X-API-Key")
                )
                result.update(
                    outcome=(
                        ("basic-auth" if feed["auth"] == "basic" else "needs-key")
                        if authenticated
                        else "open-and-working"
                    ),
                    reason="one-tariff-observed-not-location-matched",
                )
        elif meta["result"] == "json":
            features = sample_features(data)
            result.update(status=features["status"], tariffs=features["tariffs"])
            if features["locations"] == 1:
                result.update(outcome="open-and-working", reason="one-location-observed")
                if (
                    "Authorization" in headers
                    or "ec-subscription-key" in headers
                    or "X-API-Key" in headers
                ):
                    result.update(
                        outcome="basic-auth" if feed["auth"] == "basic" else "needs-key",
                        reason="working-with-credentials",
                    )
            else:
                result.update(
                    outcome="published-not-sampled",
                    reason="empty-unrecognised-or-unbounded-page",
                )
        elif kind in {"locations", "tariffs"} and meta["result"] in {
            "body-limit",
            "oversize-body-skipped",
            "encoded-body-skipped",
        }:
            result["outcome"] = "published-not-sampled"
    return result


def markdown_table(feeds: list[dict]) -> str:
    """Deterministic documentation table; tested against the committed register."""
    columns = [
        "Operator",
        "Open-data page",
        "Feed base URL",
        "Format / OCPI",
        "Modules (documented)",
        "EVSE status",
        "kWh tariffs",
        "Auth",
        "Terms",
        "Sites approx",
        "Checked / result",
        "Sources",
    ]
    lines = [
        "| " + " | ".join(columns) + " |",
        "| " + " | ".join(["---"] * len(columns)) + " |",
    ]

    def link(url, label):
        return f"[{label}]({url})" if url else "—"

    for feed in feeds:
        cells = [
            link(feed["website"], feed["name"]),
            link(feed["open_data_page"], "Page"),
            link(feed["base_url"], feed["base_url"]) if feed["base_url"] else "—",
            f"{feed['format']} / {feed['ocpi_version']}",
            ", ".join(feed["modules"]) or "unknown",
            feed["has_status"],
            feed["has_tariffs"],
            feed["auth"],
            feed["terms"],
            str(feed["sites_approx"]) if feed["sites_approx"] >= 0 else "unknown",
            f"{feed['checked_on']}: {feed['check_result']}; {feed['check_detail']}",
            " ".join(link(url, str(i + 1)) for i, url in enumerate(feed["sources"])),
        ]
        lines.append(
            "| " + " | ".join(c.replace("|", "\\|").replace("\n", " ") for c in cells) + " |"
        )
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--register", type=Path, default=REGISTER)
    parser.add_argument("--id", action="append", help="Only these operator IDs (repeatable)")
    parser.add_argument(
        "--tariffs-only",
        action="store_true",
        help="One documented tariff page instead of versions/locations; no join",
    )
    parser.add_argument("--markdown", action="store_true", help="Render stored table; no network")
    args = parser.parse_args(argv)
    feeds = tomllib.loads(args.register.read_text())["feed"]
    if args.id:
        if set(args.id) - {f["id"] for f in feeds}:
            parser.error("unknown feed ID")
        feeds = [f for f in feeds if f["id"] in args.id]
    if args.markdown:
        print(markdown_table(feeds))
        return 0
    counts = Counter()
    print(
        "Operator ID             HTTP       Versions       Status          Tariffs          "
        "Count     Link  Modules observed / Outcome / reason"
    )
    for feed in feeds:
        result = probe(feed, tariffs_only=args.tariffs_only)
        counts[result["outcome"]] += 1
        http = "/".join(str(r["http"]) if r["http"] else "ERR" for r in result["requests"]) or "—"
        versions = ",".join(result["versions"]) or "unknown"
        last = result["requests"][-1] if result["requests"] else {}
        total = last.get("total_count", -1)
        count = str(total) if total >= 0 else "unknown"
        link = "yes" if last.get("link") else "—"
        modules = ",".join(result["modules"]) or "unknown"
        print(
            f"{feed['id']:24} {http:10} {versions:14} {result['status']:15} "
            f"{result['tariffs']:16} {count:9} {link:5} {modules} / "
            f"{result['outcome']} / {result['reason']}"
        )
    print("; ".join(f"{outcome}: {counts[outcome]}" for outcome in OUTCOMES))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
