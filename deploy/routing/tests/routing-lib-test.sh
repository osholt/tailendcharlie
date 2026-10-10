#!/usr/bin/env bash
#
# Exercises the promotion and rollback policy in routing-lib.sh without Docker.
# Bash 3.2 compatible, so it runs on macOS as well as CI.

set -euo pipefail

# shellcheck source=deploy/routing/routing-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/routing-lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

calls=""
record() { calls="$calls $1"; }

build_ok() {
  record build
  echo data >"$1/graph"
}
build_fails() {
  record build
  return 1
}
candidate_ok() { record candidate; }
candidate_fails() {
  record candidate
  return 1
}
restart_ok() { record restart; }
live_ok() { record live; }
live_fails() {
  record live
  return 1
}
removed=""
remove_recorder() { removed="$removed ${1##*/}"; }

# An engine directory that has served two builds already.
engine="$work/valhalla"
fresh_engine() {
  rm -rf "$engine"
  mkdir -p "$engine/builds/old" "$engine/builds/older" "$engine/builds/oldest"
  ln -s builds/old "$engine/live"
  ln -s builds/older "$engine/previous"
  calls=""
  removed=""
}

# --- Reading the env file without executing it -------------------------------

env_file="$work/env"
cat >"$env_file" <<'ENVEOF'
ROUTING_DOMAIN=routing.example.com
ROUTING_ALLOWED_ORIGINS="https://a.example https://b.example"
ROUTING_CLIENT_IDS='tailendcharlie.app'
ROUTING_DATA_DIR=/first
ROUTING_DATA_DIR=/second
ENVEOF
test "$(routing_env_value "$env_file" ROUTING_DOMAIN)" = routing.example.com ||
  fail "plain value not read"
test "$(routing_env_value "$env_file" ROUTING_ALLOWED_ORIGINS)" = "https://a.example https://b.example" ||
  fail "double-quoted list not unquoted"
test "$(routing_env_value "$env_file" ROUTING_CLIENT_IDS)" = tailendcharlie.app ||
  fail "single-quoted value not unquoted"
test "$(routing_env_value "$env_file" ROUTING_DATA_DIR)" = /second ||
  fail "a later line did not override an earlier one, as Compose would"
test -z "$(routing_env_value "$env_file" ROUTING_MISSING)" || fail "a missing key produced a value"

# --- A successful refresh ----------------------------------------------------

fresh_engine
routing_refresh_engine "$engine" new build_ok candidate_ok restart_ok live_ok ||
  fail "a passing refresh reported failure"
test "$(routing_link_target "$engine" live)" = builds/new || fail "live does not point at the new build"
test "$(routing_link_target "$engine" previous)" = builds/old ||
  fail "previous does not point at what was serving"
test "$calls" = " build candidate restart live" || fail "unexpected sequence:$calls"
routing_prune "$engine" remove_recorder
test "$removed" = " older oldest" || fail "prune removed:$removed"

# --- A failed build never touches what is serving ---------------------------

fresh_engine
if routing_refresh_engine "$engine" new build_fails candidate_ok restart_ok live_ok 2>/dev/null; then
  fail "a failed build was reported as success"
fi
test "$(routing_link_target "$engine" live)" = builds/old || fail "a failed build moved live"
test "$(routing_link_target "$engine" previous)" = builds/older || fail "a failed build moved previous"
test ! -e "$engine/builds/new" || fail "a failed build was left on disk"
test "$calls" = " build" || fail "a failed build went on to:$calls"

# --- A candidate that fails its smoke test is never promoted -----------------

fresh_engine
if routing_refresh_engine "$engine" new build_ok candidate_fails restart_ok live_ok 2>/dev/null; then
  fail "a failed candidate was reported as success"
fi
test "$(routing_link_target "$engine" live)" = builds/old || fail "a failed candidate was promoted"
test ! -e "$engine/builds/new" || fail "a failed candidate was left on disk"
test "$calls" = " build candidate" || fail "a failed candidate went on to:$calls"

# --- A build that fails once serving is rolled straight back ----------------

fresh_engine
if routing_refresh_engine "$engine" new build_ok candidate_ok restart_ok live_fails 2>/dev/null; then
  fail "a failed serving smoke test was reported as success"
fi
test "$(routing_link_target "$engine" live)" = builds/old || fail "a failed promotion was not rolled back"
test "$calls" = " build candidate restart live restart" ||
  fail "the rollback did not restart the engine:$calls"

# --- The first ever build has nothing to roll back to -----------------------

rm -rf "$engine"
mkdir -p "$engine/builds"
calls=""
if routing_refresh_engine "$engine" first build_ok candidate_ok restart_ok live_fails 2>/dev/null; then
  fail "a failed first serving smoke test was reported as success"
fi
test "$(routing_link_target "$engine" live)" = builds/first || fail "the first build was not left live"
test -z "$(routing_link_target "$engine" previous)" || fail "a first build invented a previous one"

# --- Manual rollback is its own inverse --------------------------------------

fresh_engine
routing_rollback "$engine"
test "$(routing_link_target "$engine" live)" = builds/older || fail "rollback did not serve previous"
test "$(routing_link_target "$engine" previous)" = builds/old || fail "rollback lost the build it replaced"
routing_rollback "$engine"
test "$(routing_link_target "$engine" live)" = builds/old || fail "a second rollback did not undo the first"

rm "$engine/previous"
if (routing_rollback "$engine") 2>/dev/null; then
  fail "rollback with nothing to return to succeeded"
fi
test "$(routing_link_target "$engine" live)" = builds/old || fail "a refused rollback moved live"

echo "routing-lib: all checks passed"
