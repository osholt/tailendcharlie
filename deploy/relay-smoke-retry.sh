# shellcheck shell=bash
#
# Retry policy for the deploy smoke test, sourced by relay-deploy.sh after it
# has re-executed from the commit being deployed, and by its test.
#
# Every check the production smoke test makes is a read: liveness, readiness
# and the deployed commit. Pre-production adds a plan round trip against its own
# throwaway database. Retrying is therefore safe on both targets.
#
# Production used to get one attempt. On 5 Oct 2026 (#910) the first readiness
# request after recreating the API timed out at 15 s on the loaded 954 MB host,
# 20 seconds after liveness had passed. The deploy went red, although the relay
# was healthy on the new commit moments later. The failed smoke test rolls
# nothing back, so a false failure only hid the external verification that
# follows it.

# Attempts for a target: pre-production starts cold beside production, so it gets
# the longer allowance it has always had.
smoke_attempts_for() {
  case "$1" in
  staging) echo 12 ;;
  *) echo 6 ;;
  esac
}

# Seconds between attempts. Six production attempts ten seconds apart, each with
# the smoke test's 15 s request timeout, bound the wait at about two and a half
# minutes before a genuinely broken deploy is reported.
smoke_delay_for() {
  case "$1" in
  staging) echo 5 ;;
  *) echo 10 ;;
  esac
}

# smoke_with_retries ATTEMPTS DELAY TARGET COMMAND...
# Runs COMMAND until it succeeds or ATTEMPTS have failed, and says how long
# readiness took so the host's headroom can be followed from deploy to deploy.
smoke_with_retries() {
  local attempts="$1" delay="$2" target="$3"
  shift 3
  local attempt started="$SECONDS"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if "$@"; then
      echo "smoke: $target passed on attempt $attempt/$attempts after $((SECONDS - started)) s"
      return 0
    fi
    if ((attempt < attempts)); then
      echo "smoke: attempt $attempt/$attempts failed; retrying in $delay seconds" >&2
      sleep "$delay"
    fi
  done
  return 1
}
