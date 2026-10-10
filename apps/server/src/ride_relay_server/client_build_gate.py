"""Decide whether a client's reported app build is below the configured minimum.

The relay already refuses a client whose *protocol* is too old
(`RIDE_RELAY_MINIMUM_CLIENT_PROTOCOL`). That is the wrong tool for retiring a
single bad or ancient beta build: the protocol number only moves when the wire
format does. This module adds the second, finer cutoff (#37): a minimum app
*build number* per platform, taken from the same `x-tailendcharlie-app-build`
header every shipped build already sends.

The default is off (0). The decision is a pure function so the gate can be tested
without a request.
"""

from __future__ import annotations

import re

# Same shape the store workflows accept (tools/release/check_build_number.py):
# a plain positive integer. Anything else is not a build number.
_BUILD = re.compile(r"[1-9][0-9]{0,9}")

# Platform names exactly as the app reports them in `x-tailendcharlie-platform`
# (Flutter's `TargetPlatform.name`). Any other value - the web watcher, curl, a
# monitoring probe - is never gated: it is not a store build with an update path.
PLATFORM_IOS = "iOS"
PLATFORM_ANDROID = "android"


def parse_client_build(raw: str | None) -> int | None:
    """The build number a client reported, or None when it cannot be read."""
    text = (raw or "").strip()
    return int(text) if _BUILD.fullmatch(text) else None


def minimum_builds(*, ios: int, android: int) -> dict[str, int]:
    """The configured minimums, omitting every platform whose gate is off."""
    configured = {PLATFORM_IOS: ios, PLATFORM_ANDROID: android}
    return {platform: build for platform, build in configured.items() if build > 0}


def unmet_minimum_build(
    platform: str,
    raw_build: str | None,
    minimums: dict[str, int],
) -> int | None:
    """The minimum this client fails to meet, or None when it may proceed.

    Fail open on anything that cannot be judged. A request with no platform, an
    unknown platform, or a build that is missing, `unknown` (an unstamped local
    build) or not an integer is not something an update would fix, and refusing
    it would lock out developers and probes rather than retire an old beta.
    Every store build stamps an integer, so every real old build is judged.
    """
    minimum = minimums.get(platform)
    if minimum is None:
        return None
    build = parse_client_build(raw_build)
    if build is None or build >= minimum:
        return None
    return minimum
