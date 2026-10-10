#!/usr/bin/env python3
"""Refuse a store build number that cannot be used, before the build starts.

Both store workflows used to default `build_number` to the workflow's own run
number. That counter runs behind the numbers actually shipped, so a dispatch that
omitted the input built, signed and uploaded for ~15 minutes and was then refused
by the store ("Version code 65 has already been used", #630).

`build_number` is now a required input; this tool is the first step after
checkout and fails fast with the flag to change:

* The number must be a canonical positive integer within the store limit.
* It must be higher than every build the store already holds. Google Play
  refuses a duplicate code and silently serves testers the highest one, so a
  lower, unused code reaches nobody. App Store Connect has the same ordering.
  An equal iOS number is allowed with a notice: the upload step already treats
  "this build is already registered" as a re-run and carries on to submission.

The store lookup is best effort. If it cannot be made (network, permission, API
change) the check says so and passes, because the store's own refusal remains the
backstop. Only a lookup that succeeds and proves the number unusable fails the
run. Without credentials arguments only the format is checked.

Usage, from the repository root:

  python -m tools.release.check_build_number android --build-number 103 \\
      --package app.tailendcharlie --service-account-file play.json
  python -m tools.release.check_build_number ios --build-number 103 \\
      --bundle-id app.tailendcharlie --issuer-id ... --key-id ... \\
      --private-key AuthKey.p8
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TextIO

# Google Play's documented ceiling for a version code. Apple allows far more
# but the two platforms share one numbering sequence (docs/tester-release-notes.md),
# so one ceiling keeps them interchangeable.
MAX_BUILD_NUMBER = 2_100_000_000
_CANONICAL = re.compile(r"[1-9][0-9]{0,9}")


class BuildNumberError(ValueError):
    """The supplied build number is malformed."""


@dataclass(frozen=True)
class Verdict:
    accepted: bool
    message: str


def parse_build_number(raw: str | None) -> int:
    """Return the number, or raise with the reason it cannot be a build number."""
    text = (raw or "").strip()
    if not text:
        raise BuildNumberError(
            "build_number is empty. Pass the next unused number, higher than "
            "every build already in the store."
        )
    if not _CANONICAL.fullmatch(text):
        raise BuildNumberError(
            f"build_number {text!r} is not a plain positive integer without "
            "leading zeros or a suffix."
        )
    value = int(text)
    if value > MAX_BUILD_NUMBER:
        raise BuildNumberError(
            f"build_number {value} is above the store limit of {MAX_BUILD_NUMBER}."
        )
    return value


def judge(
    candidate: int,
    highest: int | None,
    *,
    store: str,
    allow_equal: bool = False,
) -> Verdict:
    """Decide whether `candidate` may be uploaded given the store's highest."""
    if highest is None:
        return Verdict(True, f"{store} holds no build yet; {candidate} is free.")
    if candidate > highest:
        return Verdict(True, f"{candidate} is higher than {highest}, the highest in {store}.")
    if candidate == highest and allow_equal:
        return Verdict(
            True,
            f"{candidate} is already registered in {store}; treating this as a "
            "re-run of that build.",
        )
    return Verdict(
        False,
        f"build_number {candidate} is not higher than {highest}, the highest "
        f"already in {store}. Re-run with build_number={highest + 1} or higher.",
    )


def highest_play_version_code(service: Any, package: str) -> int | None:
    """Highest version code on any track or in any bundle Play knows about.

    Uses a throwaway edit that is never committed, as `android-play-status.yml`
    does. Tracks alone are not enough: a bundle uploaded and never released
    still occupies its code.
    """
    edits = service.edits()
    edit_id = edits.insert(packageName=package, body={}).execute()["id"]
    codes: list[int] = []
    try:
        tracks = edits.tracks().list(packageName=package, editId=edit_id).execute()
        for track in tracks.get("tracks", []):
            for release in track.get("releases", []):
                codes.extend(_integers(release.get("versionCodes") or []))
        bundles = edits.bundles().list(packageName=package, editId=edit_id).execute()
        codes.extend(
            _integers(
                bundle["versionCode"]
                for bundle in bundles.get("bundles", [])
                if "versionCode" in bundle
            )
        )
    finally:
        try:
            edits.delete(packageName=package, editId=edit_id).execute()
        except Exception:  # noqa: S110 - an unused edit expires by itself
            pass
    return max(codes) if codes else None


def highest_testflight_build(client: Any, bundle_id: str) -> int | None:
    """Highest build number App Store Connect holds for the bundle id."""
    from tools.testflight.submit_external import find_app

    app = find_app(client, bundle_id)
    payload = client.request(
        "GET",
        "/builds",
        query={"filter[app]": app["id"], "sort": "-uploadedDate", "limit": "200"},
    )
    versions = ((build.get("attributes") or {}).get("version") for build in payload.get("data", []))
    numbers = _integers(v for v in versions if isinstance(v, str) and v.isdigit())
    return max(numbers) if numbers else None


def _integers(values: Iterable[Any]) -> list[int]:
    return [int(value) for value in values]


def run_check(
    raw_number: str | None,
    *,
    store: str,
    lookup: Callable[[], int | None] | None,
    allow_equal: bool = False,
    out: TextIO | None = None,
) -> int:
    """Print the outcome as workflow annotations and return the exit status."""
    out = out or sys.stdout
    try:
        candidate = parse_build_number(raw_number)
    except BuildNumberError as error:
        print(f"::error title=Invalid build_number::{error}", file=out)
        return 1
    if lookup is None:
        print(
            f"::notice::Checked the format of build_number {candidate}; no "
            f"{store} credentials were supplied, so it was not compared with "
            "the store.",
            file=out,
        )
        return 0
    try:
        highest = lookup()
    except Exception as error:  # any lookup failure is non-fatal
        print(
            f"::warning::Could not read the highest build from {store} "
            f"({type(error).__name__}: {error}). build_number {candidate} was "
            "not compared with the store; the upload step will still refuse a "
            "number the store has used.",
            file=out,
        )
        return 0
    verdict = judge(candidate, highest, store=store, allow_equal=allow_equal)
    if not verdict.accepted:
        print(f"::error title=Unusable build_number::{verdict.message}", file=out)
        return 1
    print(verdict.message, file=out)
    return 0


def _android_lookup(args: argparse.Namespace) -> Callable[[], int | None] | None:
    if not args.service_account_file:
        return None

    def lookup() -> int | None:
        from google.oauth2 import service_account
        from googleapiclient.discovery import build

        credentials = service_account.Credentials.from_service_account_file(
            args.service_account_file,
            scopes=["https://www.googleapis.com/auth/androidpublisher"],
        )
        service = build("androidpublisher", "v3", credentials=credentials, cache_discovery=False)
        return highest_play_version_code(service, args.package)

    return lookup


def _ios_lookup(args: argparse.Namespace) -> Callable[[], int | None] | None:
    if not (args.issuer_id and args.key_id and args.private_key):
        return None

    def lookup() -> int | None:
        from tools.testflight.submit_external import AppStoreConnectClient

        client = AppStoreConnectClient(
            issuer_id=args.issuer_id,
            key_id=args.key_id,
            private_key_path=Path(args.private_key),
        )
        return highest_testflight_build(client, args.bundle_id)

    return lookup


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    platforms = parser.add_subparsers(dest="platform", required=True)

    android = platforms.add_parser("android", help="Google Play version code")
    android.add_argument("--build-number", default="")
    android.add_argument("--package", default="app.tailendcharlie")
    android.add_argument("--service-account-file")

    ios = platforms.add_parser("ios", help="App Store Connect build number")
    ios.add_argument("--build-number", default="")
    ios.add_argument("--bundle-id", default="app.tailendcharlie")
    ios.add_argument("--issuer-id")
    ios.add_argument("--key-id")
    ios.add_argument("--private-key")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.platform == "android":
        return run_check(
            args.build_number,
            store="Google Play",
            lookup=_android_lookup(args),
        )
    return run_check(
        args.build_number,
        store="App Store Connect",
        lookup=_ios_lookup(args),
        allow_equal=True,
    )


if __name__ == "__main__":
    raise SystemExit(main())
