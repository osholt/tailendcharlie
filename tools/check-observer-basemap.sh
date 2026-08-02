#!/usr/bin/env bash
# Checks that a relay actually serves a usable observer basemap (#281).
#
# "Did it return 200" is not the test. The upstream answers 200 with a zero-byte
# body when the planet version is missing from the path, and a zero-byte tile
# renders an empty map without raising a MapLibre error - which is exactly the
# blank observer map this is meant to catch. So every check here asserts on
# content, and the tile check asserts on size.
#
# Usage:
#   tools/check-observer-basemap.sh https://relay.example.com
#
# Run it after deploying, and again whenever you change
# RIDE_RELAY_BASEMAP_VERSION. Exits non-zero on the first real failure so it can
# gate a deploy.
set -uo pipefail

origin="${1:-}"
if [ -z "$origin" ]; then
  echo "usage: $0 RELAY_ORIGIN" >&2
  exit 2
fi
origin="${origin%/}"

# Somewhere in the UK with roads, water and labels, so an empty tile is
# distinguishable from a tile of open sea.
z=12
x=2047
y=1362

failures=0

fail() {
  echo "  FAIL: $1" >&2
  failures=$((failures + 1))
}

echo "Checking observer basemap at $origin"

# 1. The style must be served and be a real MapLibre style, not Caddy's 404 body.
echo "- style"
style_body="$(curl -sS --max-time 20 "$origin/maps/styles/ride-relay.json" 2>/dev/null)"
style_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$origin/maps/styles/ride-relay.json" 2>/dev/null)"
if [ "$style_code" != "200" ]; then
  fail "style returned HTTP $style_code (this is the #281 symptom)"
else
  version="$(printf '%s' "$style_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
  if [ "$version" != "8" ]; then
    fail "style is not a version 8 MapLibre style"
  else
    echo "  ok: version 8 style"
  fi
  # Unrendered placeholders mean the templates directive is not applying, which
  # serves a style MapLibre cannot parse.
  case "$style_body" in
    *'{{placeholder'*)
      fail "style still contains raw template placeholders - Caddy is serving
        it unrendered. Check the templates directive declares
        'mime application/json'."
      ;;
  esac
  # The observer served from the marketing site reads this cross-origin.
  if ! curl -sS -D- -o /dev/null --max-time 20 -H 'Origin: https://example.invalid' \
    "$origin/maps/styles/ride-relay.json" 2>/dev/null \
    | grep -qi '^access-control-allow-origin'; then
    fail "style sends no Access-Control-Allow-Origin, so an observer served
        from a different origin cannot load it"
  else
    echo "  ok: readable cross-origin"
  fi
fi

# 2. A tile must have bytes. This is the check that catches the empty-200 trap.
echo "- vector tile z$z/$x/$y"
tile="$(mktemp)"
trap 'rm -f "$tile"' EXIT
tile_code="$(curl -sS -o "$tile" -w '%{http_code}' --max-time 30 \
  "$origin/maps/basemap/$z/$x/$y.pbf" 2>/dev/null)"
tile_bytes="$(wc -c < "$tile" | tr -d ' ')"
if [ "$tile_code" != "200" ]; then
  fail "tile returned HTTP $tile_code"
elif [ "$tile_bytes" -lt 1000 ]; then
  fail "tile is $tile_bytes bytes. An empty 200 means the upstream path is a
        component short - check the /maps/basemap rewrite still inserts a build
        segment, and that RIDE_RELAY_BASEMAP_VERSION is not empty."
else
  echo "  ok: $tile_bytes bytes"
fi

# 3. Glyphs, or every label silently disappears.
echo "- glyphs"
glyph="$(mktemp)"
trap 'rm -f "$tile" "$glyph"' EXIT
glyph_code="$(curl -sS -o "$glyph" -w '%{http_code}' --max-time 20 \
  "$origin/maps/fonts/Noto%20Sans%20Regular/0-255.pbf" 2>/dev/null)"
glyph_bytes="$(wc -c < "$glyph" | tr -d ' ')"
if [ "$glyph_code" != "200" ] || [ "$glyph_bytes" -lt 1000 ]; then
  fail "glyphs returned HTTP $glyph_code at $glyph_bytes bytes - labels will not draw"
else
  echo "  ok: $glyph_bytes bytes"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed - the observer map will not draw." >&2
  exit 1
fi
echo "Observer basemap is serving correctly."
