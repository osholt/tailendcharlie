#!/usr/bin/env bash

set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charging/put-credential.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
# Stand-in for ssh: run the remote command locally instead of on the host.
cat >"$work/bin/ssh" <<'SH'
#!/bin/sh
shift 3
exec sh -c "$1"
SH
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH" CHARGING_ENV_PATH="$work/charging.env"
printf 'OCPI_FEED_IONITY_TOKEN=old\nKEEP=1\n' >"$work/charging.env"
chmod 644 "$work/charging.env"

put() { printf '%s\n' "$2" | "$script" "$1" 2>&1; }

out="$(put OCPI_FEED_IONITY_TOKEN ' a=b== ')"
[[ "$out" == *"replaced OCPI_FEED_IONITY_TOKEN"* ]] || fail "replace not reported: $out"
[[ "$out" != *"a=b"* ]] || fail "value echoed"
out="$(put OCPI_FEED_GRIDSERVE_TOKEN new)"
[[ "$out" == *"added OCPI_FEED_GRIDSERVE_TOKEN"* ]] || fail "add not reported: $out"
put OCPI_FEED_BOGUS_TOKEN x >/dev/null && fail "undeclared variable accepted"
put OCPI_FEED_OSPREY_BASIC nocolon >/dev/null && fail "basic credential without colon accepted"
put OCPI_FEED_SHELL_TOKEN '' >/dev/null && fail "empty value accepted"

expected=$'KEEP=1\nOCPI_FEED_IONITY_TOKEN=a=b==\nOCPI_FEED_GRIDSERVE_TOKEN=new'
[[ "$(cat "$work/charging.env")" == "$expected" ]] || fail "unexpected env file: $(cat "$work/charging.env")"
mode="$(stat -c %a "$work/charging.env" 2>/dev/null || stat -f %Lp "$work/charging.env")"
[[ "$mode" == 600 ]] || fail "env file mode $mode"
[[ "$(find "$work" -name '.charging.env.*' | wc -l)" -eq 0 ]] || fail "temporary file left behind"

echo "put-credential: ok"
