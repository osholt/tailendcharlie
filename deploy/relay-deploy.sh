#!/usr/bin/env bash
#
# Deploy the ride relay from a pinned commit. Runs on the relay host, either by
# hand or from CI through the restricted deploy key (see relay-deploy-command).
#
#   relay-deploy.sh <staging|production> [commit]
#
# This is `docs/server-runbook.md` § "Redeploying the live relay" written down
# so it cannot be half-remembered. Everything the runbook calls load-bearing is
# load-bearing here: a detached HEAD at a pinned commit, the image stamped with
# RIDE_RELAY_BUILD_COMMIT, and `--force-recreate caddy` only when the Caddyfile
# the running proxy actually mounts has changed.
#
# No host details live in this file. The repository is public. The hostname
# comes from the host's own env file, and CI reaches the box through an
# ~/.ssh/config alias built from repository secrets.

set -euo pipefail

# Optional host configuration. Nothing here is required; the defaults describe
# the relay as it is deployed today.
#
#   RELAY_DEPLOY_REPO                  checkout both stacks are built from
#   RELAY_DEPLOY_STATE_DIR             where the last deployed commit is recorded
#   RELAY_DEPLOY_PRODUCTION_OVERRIDES  space-separated extra production compose
#                                      files, relative to deploy/. Set this to
#                                      "compose.preproduction-proxy.yaml" once
#                                      the pre-production route is enabled in
#                                      the public proxy (#398); the script then
#                                      also watches Caddyfile.preproduction,
#                                      which is the file Caddy would mount.
# shellcheck source=/dev/null
test -r /etc/relay-deploy.conf && source /etc/relay-deploy.conf

repo="${RELAY_DEPLOY_REPO:-/opt/tailendcharlie}"
state_dir="${RELAY_DEPLOY_STATE_DIR:-/var/lib/relay-deploy}"
read -r -a production_overrides <<<"${RELAY_DEPLOY_PRODUCTION_OVERRIDES:-}"

fail() {
  echo "relay-deploy: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

target="${1:-}"
requested_commit="${2:-}"

case "$target" in
staging | production) ;;
*) fail "usage: relay-deploy.sh <staging|production> [commit]" ;;
esac

if test -n "$requested_commit" && ! [[ "$requested_commit" =~ ^[0-9a-f]{40}$ ]]; then
  fail "commit must be a full 40-character SHA, received '$requested_commit'"
fi

test -d "$repo/.git" || fail "no git checkout at $repo"
cd "$repo"

# ---------------------------------------------------------------------------
# Phase 1: move the checkout, then hand over to the deploy script *of the
# commit being deployed*. Without the re-exec a change to this file would only
# take effect on the deploy after the one that merged it, so CI would be green
# for logic that never ran.
# ---------------------------------------------------------------------------
if test "${RELAY_DEPLOY_PINNED:-}" != "1"; then
  step "Fetching origin"
  git fetch --quiet origin

  commit="${requested_commit:-$(git rev-parse --verify origin/main)}"
  git cat-file -e "$commit^{commit}" 2>/dev/null || fail "unknown commit $commit"
  # Only ever deploy something that is on main. A deploy key that can pick an
  # arbitrary commit is a deploy key that can ship unreviewed code.
  git merge-base --is-ancestor "$commit" origin/main ||
    fail "$commit is not an ancestor of origin/main; refusing to deploy it"

  step "Checking out $commit (detached)"
  git checkout --quiet --detach "$commit"
  git log --oneline -1

  RELAY_DEPLOY_PINNED=1 exec "$repo/deploy/relay-deploy.sh" "$target" "$commit"
fi

# ---------------------------------------------------------------------------
# Phase 2: build and start, from the checkout of the commit being deployed.
# ---------------------------------------------------------------------------
RIDE_RELAY_BUILD_COMMIT="$(git rev-parse --verify HEAD)"
export RIDE_RELAY_BUILD_COMMIT

state_file="$state_dir/$target.commit"
previous_commit=""
if test -r "$state_file"; then
  previous_commit="$(cat "$state_file")"
fi

case "$target" in
staging)
  env_file="deploy/.env.preproduction"
  compose=(docker compose --env-file "$env_file" --file deploy/compose.preproduction.yaml)
  domain_key="RIDE_RELAY_PREPRODUCTION_DOMAIN"
  api_service="preproduction-server"
  # Staging's own containers carry no Caddy: its public route lives in the
  # production proxy. Recreating that proxy is the one action that can take
  # riders offline, so a staging deploy never touches it.
  caddyfile=""
  ;;
production)
  env_file="deploy/.env"
  compose=(docker compose --env-file "$env_file")
  compose+=(--file deploy/compose.yaml)
  caddyfile="deploy/Caddyfile"
  for override in "${production_overrides[@]}"; do
    test -n "$override" || continue
    compose+=(--file "deploy/$override")
    if test "$override" = "compose.preproduction-proxy.yaml"; then
      caddyfile="deploy/Caddyfile.preproduction"
    fi
  done
  domain_key="RIDE_RELAY_DOMAIN"
  api_service="server"
  ;;
esac

test -r "$env_file" || fail "missing $repo/$env_file"

domain="$(sed -n "s/^$domain_key=//p" "$env_file" | head -1)"
test -n "$domain" || fail "$domain_key is not set in $env_file"

step "Validating the $target compose configuration"
"${compose[@]}" config >/dev/null

step "Building and starting $target at $RIDE_RELAY_BUILD_COMMIT"
"${compose[@]}" up -d --build

# The Caddyfile is bind-mounted, and `git checkout` replaces it by rename: the
# running container keeps reading the original inode, so a plain `up -d` leaves
# it serving the pre-deploy config while reporting success. Only a recreate
# re-resolves the mount. See the runbook for the 2 August deploy this cost.
if test -n "$caddyfile" && test -n "$previous_commit"; then
  if git diff --quiet "$previous_commit" "$RIDE_RELAY_BUILD_COMMIT" -- "$caddyfile"; then
    echo "$caddyfile unchanged since $previous_commit; leaving caddy alone"
  else
    step "$caddyfile changed; recreating caddy"
    "${compose[@]}" up -d --force-recreate caddy
  fi
elif test -n "$caddyfile"; then
  # First automated deploy: nothing to diff against. Say so rather than
  # recreating the proxy on a guess.
  echo "no recorded previous $target commit; not recreating caddy." >&2
  echo "if this deploy changed $caddyfile, recreate it by hand." >&2
fi

step "Smoke testing $target over the host's internal network"
# Deliberately not the public URL. The pre-production hostname does not
# currently resolve to a working TLS route (#398), and a smoke test that has to
# traverse the public proxy is testing the proxy, not the deploy. The Host
# header is required either way: the API refuses a request whose Host is not a
# trusted name, which is why the container alias alone answers 400.
#
# `docker run`, not `docker compose run`: the pre-production API declares an
# explicit network alias, and Compose copies an explicit alias onto its one-off
# containers. A throwaway smoke container wearing the `preproduction-server`
# alias on the shared proxy network could be handed real proxied traffic for as
# long as it lived. This borrows the service's image and network and takes no
# alias at all.
container="$("${compose[@]}" ps --quiet "$api_service" | head -1)"
test -n "$container" || fail "$api_service is not running after the deploy"
smoke_image="$(docker inspect --format '{{.Image}}' "$container")"
smoke_network="$(
  docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}
{{end}}' "$container" | head -1
)"

docker run --rm --interactive \
  --network "$smoke_network" \
  --env "SMOKE_ORIGIN=http://$api_service:8080" \
  --env "SMOKE_HOST=$domain" \
  --env "SMOKE_EXPECTED_COMMIT=$RIDE_RELAY_BUILD_COMMIT" \
  --env "SMOKE_WRITE_PLAN=$(test "$target" = staging && echo 1 || echo 0)" \
  --entrypoint python "$smoke_image" - <deploy/relay-smoke.py

mkdir -p "$state_dir" 2>/dev/null ||
  fail "cannot create $state_dir; create it once, owned by $(id -un)"
printf '%s\n' "$RIDE_RELAY_BUILD_COMMIT" >"$state_file"

step "Deployed $target at $RIDE_RELAY_BUILD_COMMIT"
"${compose[@]}" ps
