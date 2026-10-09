#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=deploy/relay-smoke-retry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/relay-smoke-retry.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

calls=0
sleeps=()
# Stand-in for sleep: record the requested delay instead of waiting.
sleep() {
  sleeps+=("$1")
}

# A smoke run that fails until its Nth call.
passes_on_call() {
  calls=$((calls + 1))
  ((calls >= pass_on))
}

reset() {
  calls=0
  sleeps=()
}

# Production retries: the 5 Oct deploy failed on one slow readiness probe (#910).
test "$(smoke_attempts_for production)" -gt 1 || fail "production gets a single smoke attempt"
test "$(smoke_attempts_for production)" = "6" || fail "production attempts changed"
test "$(smoke_delay_for production)" = "10" || fail "production delay changed"
test "$(smoke_attempts_for staging)" = "12" || fail "pre-production lost its longer allowance"
test "$(smoke_delay_for staging)" = "5" || fail "pre-production delay changed"

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

reset
pass_on=1
# Not $(...): a subshell would hide the call count from this script.
smoke_with_retries 6 10 production passes_on_call >"$output_file" ||
  fail "a passing smoke run was reported as failed"
test "$calls" = "1" || fail "a passing smoke run was repeated"
test "${#sleeps[@]}" = "0" || fail "a passing smoke run waited"
grep -Fq "production passed on attempt 1/6" "$output_file" ||
  fail "the passing attempt was not reported: $(cat "$output_file")"

reset
pass_on=3
smoke_with_retries 6 10 production passes_on_call >/dev/null 2>&1 ||
  fail "a smoke run that passed on its third attempt was reported as failed"
test "$calls" = "3" || fail "retries did not stop at the first pass (calls: $calls)"
test "${sleeps[*]}" = "10 10" || fail "retries did not wait the delay between attempts: ${sleeps[*]}"

reset
pass_on=99
if smoke_with_retries 6 10 production passes_on_call >/dev/null 2>&1; then
  fail "a smoke run that never passed was reported as passing"
fi
test "$calls" = "6" || fail "a failing smoke run was not tried the full number of times (calls: $calls)"
test "${#sleeps[@]}" = "5" || fail "a failing smoke run waited after its last attempt"

echo "relay-smoke-retry tests passed"
