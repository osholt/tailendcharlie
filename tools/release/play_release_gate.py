#!/usr/bin/env python3
"""Guard rails for releases that reach Google Play's public open-testing track.

Open testing (`beta` in the API) is public: anyone with the opt-in link, or who
finds the listing, may install. On 27 July 2026 the app was found generally
available on a stale build because a release nobody meant to publish reached
that track (docs/android-internal-testing.md). Two things here make that
harder to do again:

* `gate` is the first step of every workflow that can write to `beta`. It
  refuses unless the dispatcher typed the confirmation phrase, and it refuses
  an Android Auto bundle for the open track. Open testing has a *blocking*
  Android for Cars quality review whenever the bundle is opted in to Android
  Auto (docs/open-beta-plan.md, G5), so a car-capable bundle there would put
  the whole release behind that review.
* `verify-track` reads a track back after a release and fails unless it holds
  the version code, because `fastlane supply` exiting 0 is evidence of the API
  call, not of what the track serves.

Neither command can see whether the track is paused. The Play Developer API has
no field for it; that is visible only in the Console.

Usage, from the repository root:

  python -m tools.release.play_release_gate gate \\
      --promote-to beta --confirm publish-open-testing --android-auto false
  python -m tools.release.play_release_gate verify-track \\
      --package app.tailendcharlie --track beta --version-code 103 \\
      --service-account-file play.json
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from typing import Any, TextIO

OPEN_TESTING_TRACK = "beta"
CONFIRMATION_PHRASE = "publish-open-testing"
_TRUE = {"true", "1", "yes"}
_FALSE = {"false", "0", "no", ""}


def parse_flag(raw: str | None) -> bool:
    """Read a workflow boolean, which arrives as the text `true` or `false`."""
    text = (raw or "").strip().lower()
    if text in _TRUE:
        return True
    if text in _FALSE:
        return False
    raise ValueError(f"expected true or false, got {raw!r}")


def check_open_testing_gate(
    *, promote_to: str, confirm: str, android_auto: bool
) -> tuple[bool, str]:
    """Decide whether a release to `promote_to` may proceed.

    Returns `(allowed, message)`. Only the open-testing track is gated; every
    other destination is allowed, and a stray confirmation phrase on one of
    them is ignored rather than treated as consent for anything.
    """
    track = promote_to.strip().lower()
    if track != OPEN_TESTING_TRACK:
        return True, f"{track or 'none'} is not the public open-testing track."
    if confirm.strip() != CONFIRMATION_PHRASE:
        return (
            False,
            "The beta track is Google Play open testing, which is public. Type "
            f"{CONFIRMATION_PHRASE} in confirm_open_testing to publish to it.",
        )
    if android_auto:
        return (
            False,
            "Refusing: open testing must not carry Android Auto. Its Android "
            "for Cars review is blocking, so a car-capable bundle would hold "
            "the whole open release behind that review. Run with "
            "android_auto=false.",
        )
    return True, "Confirmed: this run publishes to the public open-testing track."


def find_release(
    tracks: Sequence[dict[str, Any]], track: str, version_code: int
) -> dict[str, Any] | None:
    """The release on `track` that holds `version_code`, if any."""
    for entry in tracks:
        if entry.get("track") != track:
            continue
        for release in entry.get("releases", []):
            codes = {int(code) for code in release.get("versionCodes") or []}
            if version_code in codes:
                return release
    return None


def verify_track(service: Any, *, package: str, track: str, version_code: int) -> tuple[bool, str]:
    """Read `track` back through a throwaway edit and check for `version_code`.

    The edit is never committed. `completed` is the only status that means the
    track serves the release; a draft or in-progress release sits beside any
    live one and serves nobody, which is how a committed-but-ineffective write
    looks from the API.
    """
    edits = service.edits()
    edit_id = edits.insert(packageName=package, body={}).execute()["id"]
    try:
        tracks = edits.tracks().list(packageName=package, editId=edit_id).execute()
    finally:
        try:
            edits.delete(packageName=package, editId=edit_id).execute()
        except Exception:  # noqa: S110 - an unused edit expires by itself
            pass
    release = find_release(tracks.get("tracks", []), track, version_code)
    if release is None:
        return False, f"{track} does not hold version code {version_code}."
    status = release.get("status")
    if status != "completed":
        return (
            False,
            f"{track} holds version code {version_code} with status {status!r}, not 'completed'.",
        )
    return True, f"{track} holds version code {version_code}, status completed."


def _build_service(service_account_file: str) -> Any:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    credentials = service_account.Credentials.from_service_account_file(
        service_account_file,
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    return build("androidpublisher", "v3", credentials=credentials)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    gate = commands.add_parser("gate", help="Refuse an unconfirmed open-testing release")
    gate.add_argument("--promote-to", required=True)
    gate.add_argument("--confirm", default="")
    gate.add_argument("--android-auto", default="false")

    verify = commands.add_parser("verify-track", help="Check a track holds a version code")
    verify.add_argument("--package", required=True)
    verify.add_argument("--track", required=True)
    verify.add_argument("--version-code", required=True, type=int)
    verify.add_argument("--service-account-file", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None, out: TextIO | None = None) -> int:
    out = out or sys.stdout
    args = parse_args(argv)
    if args.command == "gate":
        try:
            android_auto = parse_flag(args.android_auto)
        except ValueError as error:
            print(f"::error title=Invalid android_auto::{error}", file=out)
            return 1
        allowed, message = check_open_testing_gate(
            promote_to=args.promote_to, confirm=args.confirm, android_auto=android_auto
        )
        if not allowed:
            print(f"::error title=Open testing is public::{message}", file=out)
            return 1
        print(message, file=out)
        return 0
    ok, message = verify_track(
        _build_service(args.service_account_file),
        package=args.package,
        track=args.track,
        version_code=args.version_code,
    )
    if not ok:
        print(f"::error title=Track read-back failed::{message}", file=out)
        return 1
    print(message, file=out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
