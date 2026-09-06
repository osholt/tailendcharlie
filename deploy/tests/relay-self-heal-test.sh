#!/usr/bin/env bash

set -euo pipefail

subject="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/relay-self-heal"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/repo/deploy" "$test_root/run" "$test_root/state"
printf 'RIDE_RELAY_DOMAIN=relay.example.test\n' >"$test_root/repo/deploy/.env"
printf 'name: test\n' >"$test_root/repo/deploy/compose.yaml"

cat >"$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_CURL_EXIT:-0}"
EOF
cat >"$test_root/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>'$test_root/docker.log'
EOF
cat >"$test_root/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>'$test_root/systemctl.log'
EOF
cat >"$test_root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
chmod +x "$test_root/bin/"*

export RELAY_SELF_HEAL_REPO="$test_root/repo"
export RELAY_SELF_HEAL_RUNTIME_DIR="$test_root/run"
export RELAY_SELF_HEAL_STATE_DIR="$test_root/state"
export RELAY_SELF_HEAL_CURL_BIN="$test_root/bin/curl"
export RELAY_SELF_HEAL_DOCKER_BIN="$test_root/bin/docker"
export RELAY_SELF_HEAL_SYSTEMCTL_BIN="$test_root/bin/systemctl"
export RELAY_SELF_HEAL_TIMEOUT_BIN="$test_root/bin/timeout"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

FAKE_CURL_EXIT=0 "$subject"
test "$(cat "$test_root/run/consecutive-failures")" = "0" || fail "success did not clear the failure count"
test ! -e "$test_root/docker.log" || fail "success attempted Docker recovery"

FAKE_CURL_EXIT=1 "$subject" && fail "the first failed probe reported success"
test "$(cat "$test_root/run/consecutive-failures")" = "1" || fail "first failure was not recorded"
assert_file_contains "$test_root/docker.log" "up -d --no-build"
test ! -e "$test_root/systemctl.log" || fail "first failure escalated too far"

FAKE_CURL_EXIT=1 "$subject" && fail "the second failed probe reported success"
test "$(cat "$test_root/run/consecutive-failures")" = "2" || fail "second failure was not recorded"
assert_file_contains "$test_root/systemctl.log" "stop docker.service docker.socket"
assert_file_contains "$test_root/systemctl.log" "restart containerd.service"
assert_file_contains "$test_root/systemctl.log" "start docker.service"

FAKE_CURL_EXIT=1 "$subject"
test "$(cat "$test_root/run/consecutive-failures")" = "3" || fail "third failure was not recorded"
assert_file_contains "$test_root/systemctl.log" "reboot"
test -s "$test_root/state/last-reboot-at" || fail "reboot cooldown was not recorded"

before="$(grep -c '^reboot$' "$test_root/systemctl.log")"
FAKE_CURL_EXIT=1 "$subject" && fail "cooldown failure reported success"
after="$(grep -c '^reboot$' "$test_root/systemctl.log")"
test "$before" = "$after" || fail "the reboot cooldown was ignored"

FAKE_CURL_EXIT=0 "$subject"
test "$(cat "$test_root/run/consecutive-failures")" = "0" || fail "recovery did not reset the failure count"

echo "relay-self-heal tests passed"
