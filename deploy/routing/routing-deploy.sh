#!/usr/bin/env bash
#
# Deploy the routing stack (Caddy, Valhalla, Photon) from a pinned commit. Runs
# on the routing host, by hand:
#
#   routing-deploy.sh [commit]
#
# The shape is relay-deploy.sh's: a detached checkout of a commit on main, a
# re-exec into that commit's copy of this script, `--force-recreate caddy` only
# when the Caddyfile the proxy mounts has changed, and a smoke test that must
# pass before the deploy is recorded. It deploys configuration and images; the
# map data is routing-data-refresh.sh's job. An engine with no data yet is
# left stopped, and the script says so.
#
# No host details live in this file. The repository is public. The hostname
# comes from deploy/routing/.env on the host.

set -euo pipefail

# Optional host configuration:
#   ROUTING_DEPLOY_REPO   checkout the stack is deployed from
# shellcheck source=/dev/null
test -r /etc/routing-deploy.conf && source /etc/routing-deploy.conf

repo="${ROUTING_DEPLOY_REPO:-/opt/tailendcharlie}"
requested_commit="${1:-}"

fail() {
  echo "routing-deploy: $*" >&2
  exit 1
}

if test -n "$requested_commit" && ! [[ "$requested_commit" =~ ^[0-9a-f]{40}$ ]]; then
  fail "commit must be a full 40-character SHA, received '$requested_commit'"
fi

test -d "$repo/.git" || fail "no git checkout at $repo"
cd "$repo"

env_file="$repo/deploy/routing/.env"
test -r "$env_file" || fail "missing $env_file; copy deploy/routing/routing.env.example"

# ---------------------------------------------------------------------------
# Phase 1: move the checkout, then hand over to this script *as it is in the
# commit being deployed*, so a change to it takes effect on the deploy that
# ships it.
# ---------------------------------------------------------------------------
if test "${ROUTING_DEPLOY_PINNED:-}" != "1"; then
  echo "==> Fetching origin"
  git fetch --quiet origin
  commit="${requested_commit:-$(git rev-parse --verify origin/main)}"
  git cat-file -e "$commit^{commit}" 2>/dev/null || fail "unknown commit $commit"
  git merge-base --is-ancestor "$commit" origin/main ||
    fail "$commit is not an ancestor of origin/main; refusing to deploy it"
  echo "==> Checking out $commit (detached)"
  git checkout --quiet --detach "$commit"
  git log --oneline -1
  ROUTING_DEPLOY_PINNED=1 exec "$repo/deploy/routing/routing-deploy.sh" "$commit"
fi

# ---------------------------------------------------------------------------
# Phase 2: from the pinned checkout.
# ---------------------------------------------------------------------------
here="$repo/deploy/routing"
# shellcheck source=deploy/routing/routing-lib.sh
source "$here/routing-lib.sh"

commit="$(git rev-parse --verify HEAD)"
data_dir="$(routing_env_value "$env_file" ROUTING_DATA_DIR)"
domain="$(routing_env_value "$env_file" ROUTING_DOMAIN)"
client_id="$(routing_env_value "$env_file" ROUTING_CLIENT_ID)"
test -n "$data_dir" || fail "ROUTING_DATA_DIR is not set in $env_file"
test -n "$domain" || fail "ROUTING_DOMAIN is not set in $env_file"
test -d "$data_dir" || fail "$data_dir does not exist; run routing-host-setup.sh first"

mkdir -p "$data_dir/state"
exec 9>>"$data_dir/state/routing.lock"
flock --nonblock 9 || fail "another routing deploy or refresh is running"

ROUTING_UID="$(id -u)"
ROUTING_GID="$(id -g)"
export ROUTING_UID ROUTING_GID
compose=(docker compose --env-file "$env_file" --file "$here/compose.yaml")

state_file="$data_dir/state/deploy.commit"
previous_commit=""
test -r "$state_file" && previous_commit="$(cat "$state_file")"

routing_step "Validating the compose configuration"
"${compose[@]}" config --quiet

routing_step "Building the Caddy and Photon images at $commit"
"${compose[@]}" build caddy photon

# Never let Compose create a missing live link as an empty root-owned
# directory: that would block the first data refresh from promoting.
services=(caddy)
for engine in valhalla photon; do
  if test -d "$data_dir/$engine/live"; then
    services+=("$engine")
  else
    echo "no $engine data yet; leaving it stopped. Run routing-data-refresh.sh $engine." >&2
  fi
done

routing_step "Starting ${services[*]}"
"${compose[@]}" up --detach --remove-orphans "${services[@]}"

# Same trap as the relay: git checkout replaces the Caddyfile by rename, and a
# running container keeps reading the old inode until it is recreated.
if test -n "$previous_commit"; then
  if git diff --quiet "$previous_commit" "$commit" -- deploy/routing/Caddyfile; then
    echo "Caddyfile unchanged since $previous_commit; leaving caddy alone"
  else
    routing_step "Caddyfile changed; recreating caddy"
    "${compose[@]}" up --detach --force-recreate --no-deps caddy
  fi
fi

if test "${#services[@]}" -lt 3; then
  echo "routing-deploy: deployed $commit without both engines; not smoke testing." >&2
  echo "routing-deploy: run routing-data-refresh.sh all, then this script again." >&2
  exit 1
fi

routing_step "Smoke testing https://$domain end to end"
# Through the public name on purpose: this is the path a phone takes, TLS and
# the client gate included. The first deploy waits for the certificate.
attempt=1
until docker run --rm --interactive \
  --env "SMOKE_PUBLIC_ORIGIN=https://$domain" \
  --env "SMOKE_CLIENT_ID=${client_id:-tailendcharlie.app}" \
  --env "SMOKE_PLANNER_ORIGIN=https://tailendcharlie.app" \
  --env "SMOKE_COUNTRIES=$(routing_env_value "$env_file" ROUTING_SMOKE_COUNTRIES)" \
  --entrypoint python3 ghcr.io/valhalla/valhalla-scripted:3.9.1 - <"$here/routing-smoke.py"; do
  if test "$attempt" -ge 12; then
    fail "smoke test failed after $attempt attempts; $commit is running but not recorded"
  fi
  echo "smoke attempt $attempt/12 failed; retrying in 10 s" >&2
  attempt=$((attempt + 1))
  sleep 10
done

printf '%s\n' "$commit" >"$state_file"
routing_step "Deployed $commit"
"${compose[@]}" ps
