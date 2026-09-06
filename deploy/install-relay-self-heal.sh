#!/usr/bin/env bash
# Install or update the root-owned relay recovery guard and its systemd timer.

set -euo pipefail

if test "$(id -u)" != "0"; then
  echo "install-relay-self-heal: run as root" >&2
  exit 1
fi

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
systemd_dir="$source_dir/systemd"

install -D -o root -g root -m 0755 \
  "$source_dir/relay-self-heal" \
  /usr/local/sbin/relay-self-heal
install -D -o root -g root -m 0644 \
  "$systemd_dir/relay-self-heal.service" \
  /etc/systemd/system/relay-self-heal.service
install -D -o root -g root -m 0644 \
  "$systemd_dir/relay-self-heal.timer" \
  /etc/systemd/system/relay-self-heal.timer
install -d -o root -g root -m 0755 /var/lib/relay-self-heal

systemctl daemon-reload
systemctl enable --now relay-self-heal.timer
if ! systemctl start relay-self-heal.service; then
  echo "install-relay-self-heal: initial probe failed; the timer will continue recovery" >&2
fi
systemctl --no-pager status relay-self-heal.timer
