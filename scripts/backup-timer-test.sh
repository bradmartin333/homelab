#!/usr/bin/env bash
set -euo pipefail

# Temporarily retarget homelab-backup.timer to fire a few minutes from now
# instead of at 03:00, so a change to the backup path can be verified without
# staying up for it — then put it back.
#
# This exists because the interesting failure is not "does the backup work" —
# `systemctl start homelab-backup.service` answers that. It is "does the timer
# schedule the NEXT run once this one finishes", which only a real timer-driven
# fire can demonstrate. In Aug 2026 the answer was no for five days and nothing
# said so: the service exited 0 every time, the healthchecks.io ping was sent,
# and the timer quietly never fired again.
#
#   ./backup-timer-test.sh arm [MINUTES]   # default 3
#   ./backup-timer-test.sh status
#   ./backup-timer-test.sh revert
#
# The drop-in lives outside the git repo, so `revert` is the only thing that
# removes it — a reinstall or a `git checkout` will not. `status` always tells
# you whether one is currently in place.

TIMER=homelab-backup.timer
SERVICE=homelab-backup.service
DROPIN_DIR="/etc/systemd/system/${TIMER}.d"
DROPIN="$DROPIN_DIR/99-test.conf"

usage() { sed -n '5,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

show_status() {
  if [ -f "$DROPIN" ]; then
    echo "!! TEST OVERRIDE ACTIVE — $DROPIN"
    echo "   run './backup-timer-test.sh revert' to restore the 03:00 schedule"
  else
    echo "-- no test override; standard 03:00 schedule"
  fi
  echo
  # The two fields that were wrong. Trigger must be a real timestamp, and the
  # service must be `inactive` between runs — `active (exited)` is the bug.
  echo "timer next fire : $(systemctl show -p NextElapseUSecRealtime --value "$TIMER" 2>/dev/null || echo '?')"
  echo "service state   : $(systemctl is-active "$SERVICE" 2>/dev/null || true) ($(systemctl show -p SubState --value "$SERVICE" 2>/dev/null || echo '?'))"
  echo
  systemctl list-timers "$TIMER" --no-pager || true
}

case "${1:-}" in
arm)
  mins="${2:-3}"
  [[ "$mins" =~ ^[0-9]+$ ]] || { echo "error: MINUTES must be a number, got '$mins'" >&2; exit 1; }
  when=$(date -d "+${mins} minutes" '+%Y-%m-%d %H:%M:%S')

  sudo mkdir -p "$DROPIN_DIR"
  # An empty assignment resets the list inherited from the unit. Without it the
  # 03:00 entry would still be there and whichever comes first would win, which
  # makes the test result ambiguous.
  sudo tee "$DROPIN" >/dev/null <<EOF
# Written by scripts/backup-timer-test.sh — TEMPORARY.
# Restore the normal schedule with: ./backup-timer-test.sh revert
[Timer]
OnCalendar=
OnCalendar=$when
# The real timer jitters by up to 5m to avoid hammering B2 on the hour. For a
# test we want it to fire when we said it would.
RandomizedDelaySec=0
# A test window that gets missed should just be missed, not trigger a catch-up
# run at some surprising later moment.
Persistent=false
EOF

  sudo systemctl daemon-reload
  sudo systemctl restart "$TIMER"
  echo "armed: $TIMER will fire once at $when (in ~${mins}m)"
  echo
  show_status
  echo
  echo "watch it run:   journalctl -u $SERVICE -f"
  echo "after it ends:  ./backup-timer-test.sh revert"
  ;;

revert)
  if [ -f "$DROPIN" ]; then
    sudo rm -f "$DROPIN"
    sudo rmdir "$DROPIN_DIR" 2>/dev/null || true
    echo "removed $DROPIN"
  else
    echo "no test override in place"
  fi
  sudo systemctl daemon-reload
  # Same reasoning as systemd/install.sh: a service left active would keep the
  # timer at `Trigger: n/a` no matter how often the timer is restarted.
  if [ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" = "active" ]; then
    echo "note: $SERVICE was left active — stopping so the timer can reschedule"
    sudo systemctl stop "$SERVICE"
  fi
  sudo systemctl restart "$TIMER"
  echo "restored standard 03:00 schedule"
  echo
  show_status
  ;;

status) show_status ;;
-h | --help | help) usage 0 ;;
*)
  echo "error: expected 'arm', 'revert', or 'status'" >&2
  echo >&2
  usage 1
  ;;
esac
