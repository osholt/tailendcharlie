#!/usr/bin/env bash
#
# One-time preparation of a fresh routing host. Idempotent; run with sudo from
# the checkout, as the account that will own the data and run the deploys:
#
#   sudo deploy/routing/routing-host-setup.sh
#
# It creates the data directory, adds a swapfile for the nightly builds, and
# installs the weekly data-refresh timer. It does not install Docker, open
# firewall ports or touch DNS; docs/routing-service.md lists those steps.

set -euo pipefail

fail() {
  echo "routing-host-setup: $*" >&2
  exit 1
}

test "$(id -u)" = 0 || fail "run with sudo"
owner="${SUDO_USER:-}"
if test -z "$owner" || test "$owner" = root; then
  fail "run with sudo from the deploy account, not as root"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=deploy/routing/routing-lib.sh
source "$here/routing-lib.sh"

env_file="$here/.env"
test -r "$env_file" || fail "missing $env_file; copy routing.env.example and fill it in first"
data_dir="$(routing_env_value "$env_file" ROUTING_DATA_DIR)"
test -n "$data_dir" || fail "ROUTING_DATA_DIR is not set in $env_file"
swap_gb="${ROUTING_SWAP_GB:-8}"

arch="$(uname -m)"
if test "$arch" != aarch64; then
  echo "warning: this host is $arch; the stack is sized for an Ampere A1 (aarch64)" >&2
fi
command -v docker >/dev/null || fail "install Docker Engine and the Compose plugin first"
docker compose version >/dev/null || fail "the Docker Compose plugin is missing"
id -nG "$owner" | tr ' ' '\n' | grep -qx docker ||
  fail "$owner is not in the docker group: usermod -aG docker $owner, then log in again"

routing_step "Data directory $data_dir, owned by $owner"
install -d -o "$owner" -g "$(id -gn "$owner")" -m 0755 \
  "$data_dir" "$data_dir/valhalla" "$data_dir/photon" "$data_dir/state"

routing_step "Swap"
# Builds run under a memory limit and may page past it rather than being
# killed. The engines that are serving are not limited by swap.
if test "$(swapon --show --noheadings | wc -l)" -gt 0; then
  echo "swap already enabled:"
  swapon --show
else
  install -m 600 /dev/null /swapfile
  dd if=/dev/zero of=/swapfile bs=1M count=$((swap_gb * 1024)) status=none
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  echo "added a ${swap_gb} GB swapfile"
fi
# Prefer dropping page cache over swapping the engines' working set.
echo 'vm.swappiness=10' >/etc/sysctl.d/90-routing.conf
sysctl --quiet --load /etc/sysctl.d/90-routing.conf

routing_step "Weekly data refresh timer"
sed -e "s|@REPO@|$repo|g" -e "s|@USER@|$owner|g" \
  "$here/systemd/routing-data-refresh.service" >/etc/systemd/system/routing-data-refresh.service
install -m 0644 "$here/systemd/routing-data-refresh.timer" /etc/systemd/system/routing-data-refresh.timer
systemctl daemon-reload
systemctl enable --now routing-data-refresh.timer
systemctl list-timers routing-data-refresh.timer --no-pager

routing_step "Host firewall"
# Oracle's Ubuntu images reject everything but SSH in iptables, beneath the
# cloud security list. Both must allow 80 and 443.
if iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  for port in 80 443; do
    if ! iptables -C INPUT -p tcp --dport "$port" -m state --state NEW -j ACCEPT 2>/dev/null; then
      echo "warning: iptables does not yet accept TCP $port; see docs/routing-service.md" >&2
    fi
  done
fi

routing_step "Done. Next: deploy/routing/routing-data-refresh.sh all, then routing-deploy.sh"
