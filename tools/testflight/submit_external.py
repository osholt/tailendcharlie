#!/usr/bin/env python3
"""Assign a processed build to external testers and submit it for beta review."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
TERMINAL_PROCESSING_FAILURES = {"FAILED", "INVALID"}
ACTIVE_REVIEW_STATES = {"APPROVED", "IN_REVIEW", "WAITING_FOR_REVIEW"}


class AppStoreConnectError(RuntimeError):
    """An App Store Connect request or release precondition failed."""


class AppStoreConnectClient:
    def __init__(self, *, issuer_id: str, key_id: str, private_key_path: Path):
        import jwt

        now = int(time.time())
        private_key = private_key_path.read_text(encoding="utf-8")
        self._token = jwt.encode(
            {
                "iss": issuer_id,
                "iat": now,
                "exp": now + 1_200,
                "aud": "appstoreconnect-v1",
            },
            private_key,
            algorithm="ES256",
            headers={"kid": key_id, "typ": "JWT"},
        )

    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
        expected: tuple[int, ...] = (200,),
    ) -> dict[str, Any]:
        url = f"{API_ROOT}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        encoded_body = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            url,
            data=encoded_body,
            method=method,
            headers={
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                if response.status not in expected:
                    raise AppStoreConnectError(
                        f"{method} {path} returned HTTP {response.status}"
                    )
                return {} if not payload else json.loads(payload)
        except urllib.error.HTTPError as error:
            response_body = error.read().decode(errors="replace")
            try:
                errors = json.loads(response_body).get("errors", [])
                detail = "; ".join(
                    item.get("detail") or item.get("title") or "unknown error"
                    for item in errors
                )
            except json.JSONDecodeError:
                detail = response_body[:500]
            raise AppStoreConnectError(
                f"{method} {path} returned HTTP {error.code}: {detail}"
            ) from error


def _single(items: list[dict[str, Any]], description: str) -> dict[str, Any]:
    if len(items) != 1:
        raise AppStoreConnectError(
            f"Expected one {description}, App Store Connect returned {len(items)}"
        )
    return items[0]


def find_app(client: Any, bundle_id: str) -> dict[str, Any]:
    payload = client.request(
        "GET",
        "/apps",
        query={"filter[bundleId]": bundle_id, "limit": "2"},
    )
    return _single(payload.get("data", []), f"app for {bundle_id}")


def wait_for_build(
    client: Any,
    *,
    app_id: str,
    build_number: str,
    timeout_seconds: int,
    poll_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_state = "not found"
    while True:
        payload = client.request(
            "GET",
            "/builds",
            query={
                "filter[app]": app_id,
                "filter[version]": build_number,
                "sort": "-uploadedDate",
                "limit": "1",
            },
        )
        builds = payload.get("data", [])
        if builds:
            build = builds[0]
            last_state = build.get("attributes", {}).get("processingState", "unknown")
            if last_state == "VALID":
                return build
            if last_state in TERMINAL_PROCESSING_FAILURES:
                raise AppStoreConnectError(
                    f"Build {build_number} processing ended in {last_state}"
                )
        if time.monotonic() >= deadline:
            raise AppStoreConnectError(
                f"Build {build_number} did not become VALID within "
                f"{timeout_seconds}s (last state: {last_state})"
            )
        print(f"Build {build_number}: {last_state}; waiting for App Store Connect")
        time.sleep(poll_seconds)


def find_external_group(client: Any, *, app_id: str, group_name: str) -> dict[str, Any]:
    payload = client.request(
        "GET",
        "/betaGroups",
        query={"filter[app]": app_id, "limit": "200"},
    )
    matches = [
        group
        for group in payload.get("data", [])
        if group.get("attributes", {}).get("name") == group_name
        and not group.get("attributes", {}).get("isInternalGroup", False)
    ]
    return _single(matches, f'external beta group named "{group_name}"')


def ensure_group_access(
    client: Any, *, build_id: str, group: dict[str, Any], dry_run: bool
) -> bool:
    payload = client.request(
        "GET",
        "/betaGroups",
        query={"filter[builds]": build_id, "limit": "200"},
    )
    if any(item.get("id") == group["id"] for item in payload.get("data", [])):
        return False
    if not dry_run:
        client.request(
            "POST",
            f"/builds/{build_id}/relationships/betaGroups",
            body={"data": [{"type": "betaGroups", "id": group["id"]}]},
            expected=(204,),
        )
    return True


def submit_for_review(client: Any, *, build_id: str, dry_run: bool) -> tuple[str, bool]:
    payload = client.request(
        "GET",
        "/betaAppReviewSubmissions",
        query={"filter[build]": build_id, "limit": "10"},
    )
    submissions = payload.get("data", [])
    if submissions:
        state = submissions[0].get("attributes", {}).get("betaReviewState", "UNKNOWN")
        if state == "REJECTED":
            raise AppStoreConnectError(
                "The build has a rejected beta review submission"
            )
        if state in ACTIVE_REVIEW_STATES:
            return state, False
        raise AppStoreConnectError(
            f"The build already has an unexpected beta review state: {state}"
        )
    if dry_run:
        return "READY_FOR_SUBMISSION", True
    response = client.request(
        "POST",
        "/betaAppReviewSubmissions",
        body={
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {
                        "data": {
                            "type": "builds",
                            "id": build_id,
                        }
                    }
                },
            }
        },
        expected=(201,),
    )
    state = response["data"].get("attributes", {}).get("betaReviewState", "SUBMITTED")
    return state, True


def append_summary(*, build_number: str, group_name: str, review_state: str) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    with Path(summary_path).open("a", encoding="utf-8") as summary:
        summary.write("### External TestFlight submission\n\n")
        summary.write(f"- Build: `{build_number}`\n")
        summary.write(f"- Tester group: `{group_name}`\n")
        summary.write(f"- Beta review state: `{review_state}`\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--group", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=1_200)
    parser.add_argument("--poll-seconds", type=int, default=20)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    client = AppStoreConnectClient(
        issuer_id=args.issuer_id,
        key_id=args.key_id,
        private_key_path=args.private_key,
    )
    app = find_app(client, args.bundle_id)
    build = wait_for_build(
        client,
        app_id=app["id"],
        build_number=args.build_number,
        timeout_seconds=args.timeout_seconds,
        poll_seconds=args.poll_seconds,
    )
    group = find_external_group(client, app_id=app["id"], group_name=args.group)
    group_added = ensure_group_access(
        client, build_id=build["id"], group=group, dry_run=args.dry_run
    )
    review_state, submitted = submit_for_review(
        client, build_id=build["id"], dry_run=args.dry_run
    )
    prefix = "Would add" if args.dry_run and group_added else "Added"
    if not group_added:
        prefix = "Already assigned"
    print(f"{prefix} build {args.build_number} to {args.group}")
    action = "would submit" if args.dry_run and submitted else "submission"
    print(f"External beta review {action}: {review_state}")
    append_summary(
        build_number=args.build_number,
        group_name=args.group,
        review_state=review_state,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AppStoreConnectError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
