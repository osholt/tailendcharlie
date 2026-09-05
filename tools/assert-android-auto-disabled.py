#!/usr/bin/env python3
"""Fail when an Android phone-release manifest exposes Android Auto."""

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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifests", nargs="+", type=Path)
    args = parser.parse_args()
    failures: list[str] = []
    for manifest in args.manifests:
        content = manifest.read_text(encoding="utf-8")
        found = [value for value in FORBIDDEN if value in content]
        if found:
            failures.append(f"{manifest}: {', '.join(found)}")
    if failures:
        print("Android Auto is still exposed by a shipped manifest:")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1
    print(
        f"Android Auto disabled in {len(args.manifests)} shipped manifest(s); "
        "preserved source set is not part of this release."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
