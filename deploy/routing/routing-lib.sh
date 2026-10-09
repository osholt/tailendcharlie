# shellcheck shell=bash
#
# Shared by routing-deploy.sh, routing-data-refresh.sh and their test. Sourced,
# never run. Must work in bash 3.2: the test runs on macOS as well as CI.
#
# The data layout under ROUTING_DATA_DIR, per engine (valhalla, photon):
#
#   <engine>/builds/<UTC stamp>/   one complete build each
#   <engine>/live     -> builds/…  what the container serves
#   <engine>/previous -> builds/…  what it served before, for rollback
#
# A refresh builds a new directory beside the live one and touches the links
# only after the candidate has passed its smoke test. A failure at any point
# before that leaves the serving data exactly as it was.

routing_fail() {
  echo "routing: $*" >&2
  exit 1
}

routing_step() {
  echo
  echo "==> $*"
}

# routing_env_value FILE KEY
# Reads one KEY=value line without executing the file, and strips one pair of
# surrounding quotes. Sourcing the env file would run any word after a space as
# a command, and the origin list is space-separated.
routing_env_value() {
  local value
  value="$(sed -n "s/^$2=//p" "$1" | tail -n 1)"
  case "$value" in
  \"*\")
    value="${value#\"}"
    value="${value%\"}"
    ;;
  \'*\')
    value="${value#\'}"
    value="${value%\'}"
    ;;
  esac
  printf '%s' "$value"
}

# routing_link_target DIR NAME
# Prints the build a link points at (builds/<stamp>), or nothing.
routing_link_target() {
  if test -L "$1/$2"; then
    readlink "$1/$2"
  fi
}

# routing_promote ENGINE_DIR STAMP
# Points live at the new build and previous at whatever live was. Relative
# links, so the data directory can be moved or mounted elsewhere intact.
routing_promote() {
  local engine_dir="$1" stamp="$2" current
  test -d "$engine_dir/builds/$stamp" || routing_fail "no build $engine_dir/builds/$stamp to promote"
  current="$(routing_link_target "$engine_dir" live)"
  if test -n "$current" && test "$current" != "builds/$stamp"; then
    ln -sfn "$current" "$engine_dir/previous"
  fi
  ln -sfn "builds/$stamp" "$engine_dir/live"
}

# routing_rollback ENGINE_DIR
# Swaps live and previous. Running it twice undoes it.
routing_rollback() {
  local engine_dir="$1" current earlier
  current="$(routing_link_target "$engine_dir" live)"
  earlier="$(routing_link_target "$engine_dir" previous)"
  test -n "$earlier" || routing_fail "$engine_dir has no previous build to roll back to"
  test -d "$engine_dir/$earlier" || routing_fail "$engine_dir/$earlier no longer exists"
  ln -sfn "$earlier" "$engine_dir/live"
  if test -n "$current"; then
    ln -sfn "$current" "$engine_dir/previous"
  fi
}

# routing_prune ENGINE_DIR REMOVE_COMMAND...
# Deletes every build that neither link points at. REMOVE_COMMAND is called
# with the directory; the engines write as the deploy user, so plain rm works,
# but the test substitutes a recorder.
routing_prune() {
  local engine_dir="$1" live previous build
  shift
  live="$(routing_link_target "$engine_dir" live)"
  previous="$(routing_link_target "$engine_dir" previous)"
  test -d "$engine_dir/builds" || return 0
  for build in "$engine_dir"/builds/*; do
    test -d "$build" || continue
    case "builds/${build##*/}" in
    "$live" | "$previous") ;;
    *) "$@" "$build" ;;
    esac
  done
}

# routing_refresh_engine ENGINE_DIR STAMP BUILD CANDIDATE_SMOKE RESTART LIVE_SMOKE
# The whole promotion policy, with every side effect passed in as a command
# name so the test can exercise it without Docker:
#
#   BUILD STAMP_DIR         produce a complete build in STAMP_DIR
#   CANDIDATE_SMOKE DIR     test that build on a throwaway container
#   RESTART                 recreate the serving container on live
#   LIVE_SMOKE              test what is now serving
#
# A failed build or candidate smoke deletes the new build and leaves live
# alone. A failed live smoke after promotion rolls back and restarts, so the
# service is back on the data that worked before the refresh began.
routing_refresh_engine() {
  local engine_dir="$1" stamp="$2" build="$3" candidate_smoke="$4" restart="$5" live_smoke="$6"
  local build_dir="$engine_dir/builds/$stamp" had_live
  had_live="$(routing_link_target "$engine_dir" live)"

  mkdir -p "$build_dir"
  if ! "$build" "$build_dir"; then
    echo "routing: build failed; $engine_dir/live is unchanged" >&2
    rm -rf "$build_dir"
    return 1
  fi
  if ! "$candidate_smoke" "$build_dir"; then
    echo "routing: candidate smoke test failed; $engine_dir/live is unchanged" >&2
    rm -rf "$build_dir"
    return 1
  fi

  routing_promote "$engine_dir" "$stamp"
  if "$restart" && "$live_smoke"; then
    return 0
  fi

  if test -z "$had_live"; then
    echo "routing: the first build passed as a candidate but not once serving;" >&2
    echo "routing: there is nothing earlier to return to. It is left live for diagnosis." >&2
    return 1
  fi
  echo "routing: serving smoke test failed after promotion; rolling back to $had_live" >&2
  routing_rollback "$engine_dir"
  "$restart" || echo "routing: restart after rollback also failed" >&2
  return 1
}
