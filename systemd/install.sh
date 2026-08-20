#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$REPO_DIR/systemd"

shopt -s nullglob
services=("$UNIT_DIR"/*.service)
timers=("$UNIT_DIR"/*.timer)
shopt -u nullglob

if [ "${#services[@]}" -eq 0 ] && [ "${#timers[@]}" -eq 0 ]; then
  echo "error: no unit files found in $UNIT_DIR" >&2
  exit 1
fi

for unit in "${services[@]}" "${timers[@]}"; do
  sudo ln -sf "$unit" "/etc/systemd/system/$(basename "$unit")"
done

sudo systemctl daemon-reload

# A oneshot left in `active (exited)` blocks its own timer permanently: systemd
# will not compute a next trigger while the triggered unit is still active. That
# is not something restarting the timer below can fix — the timer recomputes,
# sees its service active, and goes straight back to `Trigger: n/a`. Only
# returning the service to inactive clears it.
#
# This is how homelab-backup silently stopped for five days in Aug 2026: an old
# unit file set RemainAfterExit=yes, so the service never went inactive after a
# successful run.
for unit in "${services[@]}"; do
  name=$(basename "$unit")
  # Oneshots only — stopping a genuinely long-running service here would be a
  # nasty surprise for whoever adds one to this directory later.
  [ "$(systemctl show -p Type --value "$name" 2>/dev/null)" = "oneshot" ] || continue
  [ "$(systemctl is-active "$name" 2>/dev/null || true)" = "active" ] || continue
  echo "note: $name was left active after exiting — stopping it so its timer can reschedule"
  sudo systemctl stop "$name"
done

# Services are symlinked above but not enabled by that alone. Only enable the
# ones that actually declare an [Install] section — homelab-backup.service
# deliberately has none, since its timer starts it and enabling it directly
# would run a backup on every boot. Keyed on the section rather than a name
# list so the next boot-time unit dropped in here just works.
for unit in "${services[@]}"; do
  grep -q '^\[Install\]' "$unit" || continue
  sudo systemctl enable "$(basename "$unit")"
done

# Timers: enable + restart unconditionally. `enable --now` only starts a timer
# that isn't already active — if it's already active (e.g. reinstalling this
# script), that's a no-op and it won't recompute NextElapseUSecRealtime.
# restart forces it every time, which is what actually un-wedges it.
for unit in "${timers[@]}"; do
  name=$(basename "$unit")
  sudo systemctl enable "$name"
  sudo systemctl restart "$name"
done

echo "installed:"
systemctl list-timers | grep -F "$(for t in "${timers[@]}"; do basename "$t"; done | paste -sd'|')" || true
