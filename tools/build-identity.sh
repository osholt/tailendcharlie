#!/usr/bin/env bash
# Derives the build identity a Flutter artefact must report about itself.
#
# Every build channel has to stamp the same four values in, otherwise the app
# falls back to the hardcoded version in RelayClientDescriptor.current() and
# every bug report becomes ambiguous about which code it describes.
#
# Usage:
#   tools/build-identity.sh <pubspec-path> <track> [build-number]
#
# Prints KEY=VALUE lines suitable for appending to $GITHUB_ENV, or for reading
# locally to construct the matching --dart-define arguments:
#
#   tools/build-identity.sh apps/mobile/pubspec.yaml internal 123
#
# The track is the one the build is *destined for*, not necessarily the one it
# is uploaded to: an Android release uploaded to `internal` and promoted to
# `alpha` in the same run is stamped `alpha`, because that is the track its
# testers install from. Promotion never rebuilds, so this is the only chance to
# get the label right.
set -euo pipefail

pubspec="${1:?pubspec.yaml path required}"
track="${2:?distribution track required (local|ci|internal|alpha|beta|testflight)}"
build_number="${3:-}"

if [ ! -f "$pubspec" ]; then
  echo "build-identity: no pubspec at $pubspec" >&2
  exit 1
fi

case "$track" in
  local | ci | internal | alpha | beta | testflight) ;;
  *)
    echo "build-identity: unknown track '$track'" >&2
    exit 1
    ;;
esac

version_line="$(grep -E '^version:[[:space:]]*[0-9]' "$pubspec" | head -n 1 || true)"
if [ -z "$version_line" ]; then
  echo "build-identity: no 'version:' entry in $pubspec" >&2
  exit 1
fi

version_field="${version_line#version:}"
version_field="${version_field%%#*}"
version_field="$(printf '%s' "$version_field" | tr -d '[:space:]')"
version_name="${version_field%%+*}"

if [ -z "$build_number" ]; then
  case "$version_field" in
    *+*) build_number="${version_field##*+}" ;;
    *) build_number="" ;;
  esac
fi

if ! printf '%s' "$version_name" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "build-identity: '$version_name' is not a three-part version" >&2
  exit 1
fi

if ! printf '%s' "$build_number" | grep -Eq '^[0-9]+$'; then
  echo "build-identity: '$build_number' is not a positive integer build number" >&2
  exit 1
fi

printf 'RIDE_RELAY_APP_VERSION=%s\n' "$version_name"
printf 'RIDE_RELAY_APP_BUILD=%s\n' "$build_number"
printf 'RIDE_RELAY_DISTRIBUTION_TRACK=%s\n' "$track"
printf 'RIDE_RELAY_BUILD_TIMESTAMP=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
