#!/usr/bin/env bash
#
# Rebuild the routing graph and the geocoding index, test them, then promote.
# Runs on the routing host, from the weekly timer or by hand:
#
#   routing-data-refresh.sh <valhalla|photon|all>
#   routing-data-refresh.sh rollback <valhalla|photon>
#
# Each build goes into a new directory beside the one being served. It is
# served from a throwaway candidate container and smoke-tested there before the
# live link moves. A failed download, build or candidate test deletes the new
# build and leaves the service untouched. A failed test after promotion rolls
# straight back. The policy itself is routing_refresh_engine in routing-lib.sh,
# which has its own test.
#
# Builds run one at a time and under memory limits, so on the 2 OCPU / 12 GB
# Always Free shape a build that outgrows its allowance is killed rather than
# the engines that are serving. See docs/routing-service.md for sizes and times.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/routing/routing-lib.sh
source "$here/routing-lib.sh"

env_file="${ROUTING_ENV_FILE:-$here/.env}"
test -r "$env_file" || routing_fail "missing $env_file; copy routing.env.example and fill it in"

setting() {
  local value
  value="$(routing_env_value "$env_file" "$1")"
  printf '%s' "${value:-$2}"
}

data_dir="$(setting ROUTING_DATA_DIR "")"
test -n "$data_dir" || routing_fail "ROUTING_DATA_DIR is not set in $env_file"
test -d "$data_dir" || routing_fail "$data_dir does not exist; run routing-host-setup.sh first"

valhalla_image="ghcr.io/valhalla/valhalla-scripted:3.9.1"
photon_image="tec-routing-photon:1.3.0"
tools_image="tec-routing-tools:1"
candidate_network="tec-routing-candidate"
serving_network="tec-routing"

ROUTING_UID="$(id -u)"
ROUTING_GID="$(id -g)"
export ROUTING_UID ROUTING_GID
compose=(docker compose --env-file "$env_file" --file "$here/compose.yaml")

# One refresh or deploy at a time. The lock is in the data directory, which the
# deploy user owns, for the reason relay-deploy.sh gives about /run/lock.
mkdir -p "$data_dir/state"
exec 9>>"$data_dir/state/routing.lock"
flock --nonblock 9 || routing_fail "another routing deploy or refresh is running"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"

require_free_gb() {
  local need="$1" free_kb
  free_kb="$(df -Pk "$data_dir" | awk 'NR == 2 { print $4 }')"
  if test "$((free_kb / 1048576))" -lt "$need"; then
    routing_fail "$need GB free needed under $data_dir, $((free_kb / 1048576)) GB available"
  fi
}

smoke_countries="$(setting ROUTING_SMOKE_COUNTRIES GB,IE,IM,FR)"

run_smoke() {
  # Extra arguments are docker run options: the network and SMOKE_* variables.
  docker run --rm --interactive "$@" --env "SMOKE_COUNTRIES=$smoke_countries" \
    --entrypoint python3 "$valhalla_image" - <"$here/routing-smoke.py"
}

remove_build() {
  echo "pruning $1"
  rm -rf "$1"
}

ensure_candidate_network() {
  docker network inspect "$candidate_network" >/dev/null 2>&1 ||
    docker network create "$candidate_network" >/dev/null
}

# wait_for URL_ON_CANDIDATE_NETWORK SECONDS
wait_for() {
  local url="$1" seconds="$2" waited=0
  until docker run --rm --network "$candidate_network" --entrypoint curl "$valhalla_image" \
    --fail --silent --max-time 5 --output /dev/null "$url"; do
    waited=$((waited + 5))
    if test "$waited" -ge "$seconds"; then
      echo "routing: $url did not answer within $seconds s" >&2
      return 1
    fi
    sleep 5
  done
}

# --- Valhalla ---------------------------------------------------------------

build_valhalla() {
  local dir="$1" urls threads memory max_km
  urls="$(setting ROUTING_PBF_URLS "")"
  test -n "$urls" || routing_fail "ROUTING_PBF_URLS is not set"
  threads="$(setting VALHALLA_BUILD_THREADS 2)"
  memory="$(setting VALHALLA_BUILD_MEMORY_LIMIT 7g)"
  max_km="$(setting VALHALLA_MAX_ROUTE_KM 1500)"

  routing_step "Valhalla: downloading and merging extracts into $dir"
  docker build --quiet --tag "$tools_image" "$here/tools" >/dev/null || return 1
  # shellcheck disable=SC2016 # expanded inside the container
  docker run --rm --user "$ROUTING_UID:$ROUTING_GID" \
    --volume "$dir:/work" --env "ROUTING_PBF_URLS=$urls" "$tools_image" \
    bash -euo pipefail -c '
      for url in $ROUTING_PBF_URLS; do
        name="${url##*/}"
        curl --fail --location --silent --show-error --retry 3 --output "$name" "$url"
        curl --fail --location --silent --show-error --retry 3 --output "$name.md5" "$url.md5"
        md5sum --check --strict "$name.md5"
        rm "$name.md5"
        set -- "$@" "$name"
      done
      osmium merge --overwrite --output merged.osm.pbf "$@"
      rm -- "$@"
      osmium fileinfo merged.osm.pbf | grep -E "Bounding|Size"
    ' || return 1

  routing_step "Valhalla: building tiles, admin and time-zone databases ($threads threads, $memory)"
  docker run --rm --user "$ROUTING_UID:$ROUTING_GID" \
    --memory "$memory" --memory-swap -1 \
    --volume "$dir:/custom_files" \
    --env serve_tiles=False --env force_rebuild=True --env use_tiles_ignore_pbf=False \
    --env build_admins=True --env build_time_zones=True --env build_elevation=False \
    --env build_tar=True --env use_default_speeds_config=True \
    --env "server_threads=$threads" \
    "$valhalla_image" build_tiles || return 1

  routing_step "Valhalla: tuning the service configuration"
  # Valhalla's default longest route is 500 km, which a long day in France
  # exceeds.
  # shellcheck disable=SC2016 # expanded inside the container
  docker run --rm --user "$ROUTING_UID:$ROUTING_GID" \
    --volume "$dir:/custom_files" --env "MAX_METERS=$((max_km * 1000))" \
    --entrypoint bash "$valhalla_image" -euo pipefail -c '
      config=/custom_files/valhalla.json
      jq --argjson max "$MAX_METERS" \
        ".service_limits.auto.max_distance = \$max | .service_limits.motorcycle.max_distance = \$max" \
        "$config" | sponge "$config"
      rm -rf /custom_files/valhalla_tiles /custom_files/merged.osm.pbf
      for required in valhalla_tiles.tar admins.sqlite timezones.sqlite valhalla.json; do
        test -s "/custom_files/$required" || { echo "build is missing $required" >&2; exit 1; }
      done
      du -sh /custom_files
    '
}

candidate_valhalla() {
  local dir="$1" name="tec-routing-valhalla-candidate" status=0
  ensure_candidate_network
  docker rm --force "$name" >/dev/null 2>&1 || true
  docker run --detach --name "$name" --network "$candidate_network" \
    --user "$ROUTING_UID:$ROUTING_GID" --volume "$dir:/custom_files:ro" \
    --entrypoint valhalla_service "$valhalla_image" /custom_files/valhalla.json 1 >/dev/null
  if wait_for "http://$name:8002/status" 180; then
    run_smoke --network "$candidate_network" \
      --env "SMOKE_VALHALLA_ORIGIN=http://$name:8002" || status=$?
  else
    docker logs --tail 50 "$name" >&2 || true
    status=1
  fi
  docker rm --force "$name" >/dev/null 2>&1 || true
  return "$status"
}

restart_valhalla() {
  "${compose[@]}" up --detach --force-recreate --no-deps valhalla
}

smoke_serving_valhalla() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if run_smoke --network "$serving_network" --env SMOKE_VALHALLA_ORIGIN=http://valhalla:8002; then
      return 0
    fi
    echo "serving Valhalla not ready (attempt $attempt/12)" >&2
    sleep 10
  done
  return 1
}

# --- Photon -----------------------------------------------------------------

build_photon() {
  local dir="$1" url countries languages heap memory
  url="$(setting PHOTON_DUMP_URL "")"
  test -n "$url" || routing_fail "PHOTON_DUMP_URL is not set"
  countries="$(setting PHOTON_COUNTRY_CODES GB,IE,IM,FR)"
  languages="$(setting PHOTON_LANGUAGES en,fr)"
  heap="$(setting PHOTON_IMPORT_HEAP 3g)"
  memory="$(setting PHOTON_IMPORT_MEMORY_LIMIT 5g)"

  routing_step "Photon: streaming $url into a $countries index ($heap heap, $memory)"
  # The Europe dump is about 13 GB compressed. It is streamed, never stored, and
  # checksummed on the way through: a corrupt or truncated download fails the
  # import instead of producing a half-empty index.
  # shellcheck disable=SC2016 # expanded inside the container
  docker run --rm --user "$ROUTING_UID:$ROUTING_GID" \
    --memory "$memory" --memory-swap -1 \
    --volume "$dir:/photon" \
    --env "DUMP_URL=$url" --env "COUNTRIES=$countries" --env "LANGUAGES=$languages" \
    --env "HEAP=$heap" \
    --entrypoint bash "$photon_image" -euo pipefail -c '
      expected="$(curl --fail --location --silent --show-error --retry 3 "$DUMP_URL.md5" | cut -d " " -f 1)"
      test -n "$expected"
      curl --fail --location --silent --show-error --retry 3 "$DUMP_URL" |
        tee >(md5sum | cut -d " " -f 1 >/tmp/received.md5) |
        zstd --decompress --stdout |
        java "-Xmx$HEAP" -jar /opt/photon.jar import -import-file - -data-dir /photon \
          -country-codes "$COUNTRIES" -languages "$LANGUAGES"
      # The process substitution finishes asynchronously; wait for its file.
      for _ in 1 2 3 4 5 6 7 8 9 10; do test -s /tmp/received.md5 && break; sleep 1; done
      received="$(cat /tmp/received.md5)"
      if test "$received" != "$expected"; then
        echo "dump checksum $received does not match published $expected" >&2
        exit 1
      fi
      du -sh /photon
    '
}

candidate_photon() {
  local dir="$1" name="tec-routing-photon-candidate" status=0
  ensure_candidate_network
  docker rm --force "$name" >/dev/null 2>&1 || true
  docker run --detach --name "$name" --network "$candidate_network" \
    --user "$ROUTING_UID:$ROUTING_GID" --volume "$dir:/photon" "$photon_image" \
    -Xmx1g -jar /opt/photon.jar serve -data-dir /photon -listen-ip 0.0.0.0 >/dev/null
  if wait_for "http://$name:2322/status" 300; then
    run_smoke --network "$candidate_network" \
      --env "SMOKE_PHOTON_ORIGIN=http://$name:2322" || status=$?
  else
    docker logs --tail 50 "$name" >&2 || true
    status=1
  fi
  docker rm --force "$name" >/dev/null 2>&1 || true
  return "$status"
}

restart_photon() {
  "${compose[@]}" up --detach --force-recreate --no-deps photon
}

smoke_serving_photon() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    if run_smoke --network "$serving_network" --env SMOKE_PHOTON_ORIGIN=http://photon:2322; then
      return 0
    fi
    echo "serving Photon not ready (attempt $attempt/18)" >&2
    sleep 10
  done
  return 1
}

# --- Orchestration ----------------------------------------------------------

refresh() {
  local engine="$1" engine_dir="$data_dir/$1" need
  case "$engine" in
  valhalla) need=50 ;;
  photon) need=20 ;;
  esac
  mkdir -p "$engine_dir/builds"
  # Keep the serving build and the one before it; anything older goes first,
  # so the free-space check measures what this build can really use.
  routing_prune "$engine_dir" remove_build
  require_free_gb "$need"
  if test "$engine" = photon; then
    "${compose[@]}" build photon
  fi
  # Explicit, because set -e does not reach inside a function called from the
  # `refresh valhalla || status=1` list below.
  routing_refresh_engine "$engine_dir" "$stamp" \
    "build_$engine" "candidate_$engine" "restart_$engine" "smoke_serving_$engine" ||
    return 1
  routing_prune "$engine_dir" remove_build
  printf '%s %s\n' "$stamp" "$(routing_link_target "$engine_dir" live)" \
    >"$data_dir/state/$engine.refreshed"
  routing_step "$engine now serving $(routing_link_target "$engine_dir" live)"
}

case "${1:-}" in
valhalla | photon)
  refresh "$1"
  ;;
all)
  # Sequential on purpose: two builds at once do not fit beside the engines
  # that are serving. A Valhalla failure still lets Photon refresh.
  status=0
  refresh valhalla || status=1
  refresh photon || status=1
  exit "$status"
  ;;
rollback)
  engine="${2:-}"
  case "$engine" in
  valhalla | photon) ;;
  *) routing_fail "usage: routing-data-refresh.sh rollback <valhalla|photon>" ;;
  esac
  routing_rollback "$data_dir/$engine"
  "restart_$engine"
  "smoke_serving_$engine"
  routing_step "$engine rolled back to $(routing_link_target "$data_dir/$engine" live)"
  ;;
*)
  routing_fail "usage: routing-data-refresh.sh <valhalla|photon|all> | rollback <valhalla|photon>"
  ;;
esac
