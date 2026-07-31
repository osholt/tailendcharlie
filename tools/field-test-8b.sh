#!/usr/bin/env bash
# Drives step 8b of docs/field-test-plan.md - idle-device delivery (#132, #134,
# #99) - across two devices running a build with the test-control define, and
# prints the observed delay in each direction.
#
# 8b is the step this exists for. Its assertions are about two phones sitting
# untouched, and its measurement is a delay in seconds. A person tapping two
# phones cannot produce that number while also reading both screens, and the
# moment they pick a phone up to look, the phone is no longer idle - which is the
# precise condition under test.
#
# Usage:
#   tools/field-test-8b.sh LEADER_HOST LEADER_TOKEN FOLLOWER_HOST FOLLOWER_TOKEN
#
# Each host is the phone's address on the network; the token is shown in
# Settings -> Field test control on that phone. Nothing is written to the
# repository - paste the output into docs/field-test-results.md yourself, so the
# record is something a person chose to keep.
set -uo pipefail

if [ "$#" -ne 4 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

LEADER_HOST="$1"; LEADER_TOKEN="$2"
FOLLOWER_HOST="$3"; FOLLOWER_TOKEN="$4"
PORT="${TEST_CONTROL_PORT:-8477}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# curl exits 0 on a 4xx, and the surface answers 4xx with {"error": ...} when an
# action was swallowed by RideController._run rather than performed. Checking the
# body is therefore the only way to know an action happened. An earlier version
# of this script checked curl's exit code alone and cheerfully reported
# "previous ride ended" and then the *previous* ride's code, for an end refused
# because the local rider was Tail End Charlie rather than the leader.
must() { # description, then the call output
  local what="$1" out="$2"
  local err
  err=$(jq -r '.error // empty' <<<"$out" 2>/dev/null)
  if [ -n "$err" ]; then
    fail "$what: $err - $(jq -r '.detail // ""' <<<"$out" 2>/dev/null)"
  fi
  [ -n "$out" ] || fail "$what: empty response"
}

# $1 host, $2 token, $3 method, $4 path, $5 optional JSON body
call() {
  local host="$1" token="$2" method="$3" path="$4" body="${5-}"
  local args=(-sS --max-time 20 -X "$method"
    -H "Authorization: Bearer $token" "http://$host:$PORT$path")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}"
}

jq_or_fail() { command -v jq >/dev/null || fail 'jq is required'; }
jq_or_fail

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

printf '== step 8b: idle-device delivery ==\n'

# --- reachability -----------------------------------------------------------
for pair in "leader:$LEADER_HOST" "follower:$FOLLOWER_HOST"; do
  role="${pair%%:*}"; host="${pair#*:}"
  status=$(curl -sS --max-time 10 "http://$host:$PORT/v1/health" |
    jq -r '.status // "unreachable"' 2>/dev/null || echo unreachable)
  [ "$status" = ok ] || fail "$role at $host is not answering /v1/health"
  printf '  %-9s reachable\n' "$role"
done

# --- 0. start from a known state --------------------------------------------
# A driven run must not inherit a ride: createRide refuses while one is active,
# and a run that silently continued against the previous ride would describe the
# wrong thing entirely.
#
# `end` is leader-only - RideController throws "Only the ride leader can end the
# ride" for anyone else - so a phone holding a ride as Tail End Charlie or marker
# needs `leave` instead. Both are attempted, errors ignored, and the create below
# is the real check.
clear_ride() {
  local label="$1" host="$2" tok="$3" code
  code=$(call "$host" "$tok" GET /v1/state | jq -r '.ride.rideCode // empty')
  if [ -z "$code" ]; then
    printf '  %-9s no ride to clear\n' "$label"
    return 0
  fi
  printf '  %-9s clearing ride %s\n' "$label" "$code"
  call "$host" "$tok" POST /v1/ride/end >/dev/null 2>&1
  call "$host" "$tok" POST /v1/ride/leave >/dev/null 2>&1
}

printf '\n-- 0. clearing any existing ride --\n'
clear_ride leader "$LEADER_HOST" "$LEADER_TOKEN"
clear_ride follower "$FOLLOWER_HOST" "$FOLLOWER_TOKEN"

# --- 1. create, join, start -------------------------------------------------
printf '\n-- 1. create, join, start --\n'
created=$(call "$LEADER_HOST" "$LEADER_TOKEN" POST /v1/ride \
  '{"displayName":"Leader"}')
must 'create ride' "$created"

invite=$(call "$LEADER_HOST" "$LEADER_TOKEN" GET /v1/ride/invite)
code=$(jq -r '.rideCode' <<<"$invite")
token=$(jq -r '.joinToken // empty' <<<"$invite")
[ -n "$code" ] && [ "$code" != null ] || fail "no ride code: $invite"
printf '  ride code %s\n' "$code"

joined=$(call "$FOLLOWER_HOST" "$FOLLOWER_TOKEN" POST /v1/ride/join \
  "$(jq -nc --arg c "$code" --arg t "$token" \
    '{rideCode:$c, displayName:"Follower"} + (if $t=="" then {} else {joinToken:$t} end)')")
must 'join ride' "$joined"

started_out=$(call "$LEADER_HOST" "$LEADER_TOKEN" POST /v1/ride/start)
must 'start ride' "$started_out"
printf '  started\n'

# The ride code must be a NEW one. A create that silently no-opped would leave the
# previous ride in place and every number below would describe the wrong ride.
printf '  leader ride now: %s\n' "$(jq -r '.ride.rideCode // "none"' <<<"$started_out")"

# --- 2. both untouched for two minutes --------------------------------------
# Untouched is the whole point. Nothing is sent to either device in this window,
# so a device that only receives when it also sends will be caught here.
printf '\n-- 2. two minutes untouched --\n'
sleep 120

for pair in "leader:$LEADER_HOST:$LEADER_TOKEN" "follower:$FOLLOWER_HOST:$FOLLOWER_TOKEN"; do
  role="${pair%%:*}"; rest="${pair#*:}"; host="${rest%%:*}"; tok="${rest#*:}"
  state=$(call "$host" "$tok" GET /v1/state)
  gate=$(jq -r '.reconciliation.gateSatisfied' <<<"$state")
  roster=$(jq -r '.reconciliation.rosterCount' <<<"$state")
  placed=$(jq -r '.reconciliation.withPosition | length' <<<"$state")
  orphan=$(jq -r '.reconciliation.countedWithoutPositionOrReason | join(",")' <<<"$state")
  printf '  %-9s roster=%s placed=%s gate=%s\n' "$role" "$roster" "$placed" "$gate"
  if [ "$gate" != true ]; then
    printf '    counted with no position and no reason: %s\n' "${orphan:-none}"
    printf '    ^ this is the #132 signature\n'
  fi
done

# --- 3. hazard in each direction, measured ----------------------------------
# measure LABEL FROM_HOST FROM_TOKEN TO_HOST TO_TOKEN LAT LON TYPE
#
# Identifies the hazard by its own id, not by counting. Three earlier versions of
# this got it wrong and each would have produced a confident wrong answer:
#
#  1. counted `.presence[]`, which never changes when a hazard lands;
#  2. compared counts with `-ge`, true when equal, so it reported instant
#     delivery every time;
#  3. counted `.hazards[]` but sent both directions to the SAME coordinates -
#     HazardDeduplicator merges same-type reports within 75 m, so the second
#     hazard was absorbed into the first and the count never moved. That looked
#     exactly like a one-way delivery failure and was purely self-inflicted.
#
# So each direction uses its own position, far enough apart that dedup cannot
# merge them, and arrival is "this specific id is present on the receiver".
measure() {
  local label="$1" from_h="$2" from_t="$3" to_h="$4" to_t="$5"
  local lat="$6" lon="$7" htype="$8"
  local before_ids posted new_id started elapsed

  before_ids=$(call "$from_h" "$from_t" GET /v1/state | jq -r '[.hazards[].id] | join(" ")')

  started=$(now_ms)
  posted=$(call "$from_h" "$from_t" POST /v1/hazard \
    "$(jq -nc --arg t "$htype" --argjson la "$lat" --argjson lo "$lon" \
      '{type:$t, severity:"caution", latitude:$la, longitude:$lo}')")
  if [ -n "$(jq -r '.error // empty' <<<"$posted")" ]; then
    printf '  %-24s report refused: %s\n' "$label" "$(jq -r '.detail' <<<"$posted")"
    return 1
  fi

  # The id the sender now holds that it did not hold before.
  new_id=$(jq -r --arg before "$before_ids" \
    '[.hazards[].id] - ($before | split(" ")) | first // empty' <<<"$posted")
  if [ -z "$new_id" ]; then
    printf '  %-24s sender did not record a new hazard (deduplicated locally?)\n' "$label"
    return 1
  fi

  # Poll the RECEIVER only. A device that only makes progress when it has
  # something of its own to upload will time out here rather than appear to work.
  for _ in $(seq 1 60); do
    if call "$to_h" "$to_t" GET /v1/state \
      | jq -e --arg id "$new_id" 'any(.hazards[]; .id == $id)' >/dev/null 2>&1; then
      elapsed=$(( $(now_ms) - started ))
      printf '  %-24s %s ms\n' "$label" "$elapsed"
      return 0
    fi
    sleep 1
  done
  printf '  %-24s NO DELIVERY within 60s (hazard %s never arrived)\n' "$label" "$new_id"
  return 1
}

printf '\n-- 3. hazard delivery delay --\n'
# Positions ~2 km apart and different hazard types, so the deduplicator cannot
# merge one direction's report into the other's.
measure 'follower -> leader' "$FOLLOWER_HOST" "$FOLLOWER_TOKEN" \
  "$LEADER_HOST" "$LEADER_TOKEN" 51.2000 -2.4000 roadworks
measure 'leader -> follower' "$LEADER_HOST" "$LEADER_TOKEN" \
  "$FOLLOWER_HOST" "$FOLLOWER_TOKEN" 51.2200 -2.4300 flooding

# --- tidy up ----------------------------------------------------------------
printf '\n-- ending ride --\n'
call "$LEADER_HOST" "$LEADER_TOKEN" POST /v1/ride/end >/dev/null &&
  printf '  ended\n'

cat <<'NOTE'

Sub-step 4 (swap the roles and repeat) is this script run again with the two
host/token pairs exchanged. The result must be identical: the failure must not
follow either the role or the device.

Sub-step 5 (a clock five minutes wrong, each direction) is not automatable from
here - the date and time setting is an OS setting, not an app one. Set it by
hand, then read /v1/state and check publisherClockOffsetSeconds is reported and
the rider is still live.

Record the observed delays, both device models, and the build number in
docs/field-test-results.md. These are iOS-to-iOS or relay-transport figures
unless a physical Android phone was one of the two devices - an emulator result
never satisfies a radio, battery or real-GPS gate.
NOTE
