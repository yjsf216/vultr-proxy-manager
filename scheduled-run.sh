#!/bin/bash
set -u

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MANAGER="$SCRIPT_DIR/vultr-proxy.sh"
LOG="$SCRIPT_DIR/.state/scheduler.log"
ACTION=${1:-}
HOUR=$((10#$(date +%H)))

mkdir -p "$SCRIPT_DIR/.state"
chmod 700 "$SCRIPT_DIR/.state"
exec >> "$LOG" 2>&1

echo "$(date '+%F %T') start $ACTION"

notify() {
  /usr/bin/osascript -e "display notification \"$2\" with title \"Vultr Proxy $1\"" >/dev/null 2>&1 || true
}

case "$ACTION" in
  delete)
    if [ "$HOUR" -lt 21 ] || [ "$HOUR" -gt 23 ]; then
      echo "Skipped late delete outside 21:00-23:59"
      exit 0
    fi
    if "$MANAGER" delete --yes; then
      notify Deleted "Server deleted; billing stopped"
      echo "$(date '+%F %T') delete complete"
    else
      notify Failed "Nightly server deletion failed; check scheduler.log"
      exit 1
    fi
    ;;
  create)
    if [ "$HOUR" -lt 8 ] || [ "$HOUR" -gt 20 ]; then
      echo "Skipped create outside 08:00-20:59"
      exit 0
    fi
    for attempt in 1 2; do
      echo "Create attempt $attempt"
      if "$MANAGER" create --yes && "$MANAGER" test; then
        notify Ready "Server and subscription are ready"
        echo "$(date '+%F %T') create complete"
        if [ -f "$SCRIPT_DIR/.state/one-night-trial" ]; then
          uid=$(id -u)
          launchctl disable "gui/$uid/com.vultr.proxy-manager-create"
          launchctl disable "gui/$uid/com.vultr.proxy-manager-delete"
          mv "$SCRIPT_DIR/.state/one-night-trial" "$SCRIPT_DIR/.state/one-night-trial.completed"
          echo "One-night trial complete; daily jobs disabled"
        fi
        exit 0
      fi
      echo "Attempt $attempt failed"
      [ "$attempt" -eq 2 ] || "$MANAGER" delete --yes || true
      sleep 60
    done
    notify Failed "Morning server creation failed twice; check scheduler.log"
    exit 1
    ;;
  *)
    echo "Usage: $(basename "$0") create|delete" >&2
    exit 2
    ;;
esac
