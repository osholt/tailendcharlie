#!/usr/bin/env python3
"""Check whether an Android release manifest exposes Android Auto.

By default every shipped manifest must be free of Android Auto: that is the
state of every Play bundle since build 88, and the only state open testing may
have (docs/open-beta-plan.md, G5). `--expect enabled` is the opposite check for
a bundle deliberately built with `-PandroidAuto=true`, so the switch cannot
silently do nothing.
"""

from __future__ import annotations

import argparse
from pathlib import Path


FORBIDDEN = (
    "androidx.car.app.NAVIGATION_TEMPLATES",
    "androidx.car.app.ACCESS_SURFACE",
    "com.google.android.gms.car.application",
    "androidx.car.app.CarAppService",
    "androidx.car.app.category.NAVIGATION",
    "androidx.car.app.action.NAVIGATE",
    "TailEndCharlieCarAppService",
    "androidx.car.app.connection.provider",
    "androidx.car.app.CarAppMetadataHolderService",
    "androidx.car.app.CarAppPermissionActivity",
    "androidx.car.app.notification.CarAppNotificationBroadcastReceiver",
)

# What an Android Auto build must declare. Narrower than FORBIDDEN on purpose:
# these come from this repository's own `src/androidAuto` manifest, while the
# rest of FORBIDDEN arrives from the Car App Library's merged manifests.
REQUIRED = (
    "androidx.car.app.NAVIGATION_TEMPLATES",
    "androidx.car.app.CarAppService",
    "androidx.car.app.category.NAVIGATION",
    "com.google.android.gms.car.application",
    "TailEndCharlieCarAppService",
)


def check(manifests: list[Path], expect: str) -> list[str]:
    """Return one failure line per manifest that does not match `expect`."""
    failures: list[str] = []
    for manifest in manifests:
        content = manifest.read_text(encoding="utf-8")
        if expect == "disabled":
            found = [value for value in FORBIDDEN if value in content]
            if found:
                failures.append(f"{manifest}: {', '.join(found)}")
        else:
            missing = [value for value in REQUIRED if value not in content]
            if missing:
                failures.append(f"{manifest}: missing {', '.join(missing)}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifests", nargs="+", type=Path)
    parser.add_argument(
        "--expect",
        choices=("disabled", "enabled"),
        default="disabled",
        help="disabled (default): fail if Android Auto is declared; "
        "enabled: fail if it is not",
    )
    args = parser.parse_args()
    failures = check(args.manifests, args.expect)
    if failures and args.expect == "disabled":
        print("Android Auto is still exposed by a shipped manifest:")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1
    if failures:
        print("Android Auto was requested but is not declared:")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1
    if args.expect == "enabled":
        print(
            f"Android Auto declared in {len(args.manifests)} manifest(s), "
            "as the Android Auto build requires."
        )
        return 0
    print(
        f"Android Auto disabled in {len(args.manifests)} shipped manifest(s); "
        "preserved source set is not part of this release."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
