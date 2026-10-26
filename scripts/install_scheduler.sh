#!/bin/bash
# Install (or remove) the daily job-scan scheduler.
#   macOS: launchd agent   Linux: crontab entry
# Usage: bash scripts/install_scheduler.sh            # install / reinstall
#        bash scripts/install_scheduler.sh --uninstall
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPTS_DIR")"
SCAN_SCRIPT="$SCRIPTS_DIR/daily_scan.sh"
LABEL="com.job-scan.daily"
CRON_TAG="# job-scan:$REPO_DIR"

PYTHON="$(command -v python3 || true)"
[ -x "$PYTHON" ] || PYTHON=/usr/bin/python3

# launchd/cron start with a bare PATH; capture where python3 and claude live now.
SCHED_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for bin in python3 claude; do
    if p="$(command -v "$bin" 2>/dev/null)"; then
        SCHED_PATH="$(dirname "$p"):$SCHED_PATH"
    else
        [ "$bin" = claude ] && echo "warning: claude not found on PATH; auto-scoring will be skipped" >&2
    fi
done
[ -d /opt/homebrew/bin ] && SCHED_PATH="/opt/homebrew/bin:$SCHED_PATH"

FETCH_TIME="$("$PYTHON" - "$REPO_DIR/preferences.toml" <<'PY' 2>/dev/null || echo 07:00
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        print(tomllib.load(f).get("schedule", {}).get("fetch_time", "07:00"))
except Exception:
    print("07:00")
PY
)"
if ! [[ "$FETCH_TIME" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    echo "invalid schedule.fetch_time '$FETCH_TIME' (expected HH:MM)" >&2; exit 1
fi
HOUR=$((10#${FETCH_TIME%%:*}))
MINUTE=$((10#${FETCH_TIME##*:}))

UNINSTALL=false
[ "${1:-}" = "--uninstall" ] && UNINSTALL=true

case "$(uname -s)" in
Darwin)
    PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
    LOG="$HOME/Library/Logs/job-scan.launchd.log"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    if $UNINSTALL; then
        rm -f "$PLIST"; echo "Removed $PLIST"; exit 0
    fi
    mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCAN_SCRIPT}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${HOUR}</integer>
        <key>Minute</key>
        <integer>${MINUTE}</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${SCHED_PATH}</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
        <key>LC_ALL</key>
        <string>en_US.UTF-8</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLISTEOF
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed launchd agent: $PLIST"
    echo "  Schedule:   daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
    echo "  Logs:       $LOG and ~/Library/Logs/job-scan.log"
    echo "  Run now:    launchctl kickstart gui/$(id -u)/$LABEL"
    echo "  Uninstall:  bash $0 --uninstall"
    ;;
Linux)
    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/job-scan"
    CURRENT="$(crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true)"
    if $UNINSTALL; then
        printf '%s\n' "$CURRENT" | crontab -; echo "Removed cron entry"; exit 0
    fi
    mkdir -p "$STATE_DIR"
    LINE="$MINUTE $HOUR * * * PATH=$SCHED_PATH /bin/bash $SCAN_SCRIPT >> $STATE_DIR/cron.log 2>&1 $CRON_TAG"
    printf '%s\n%s\n' "$CURRENT" "$LINE" | sed '/^$/d' | crontab -
    echo "Installed cron entry:"
    echo "  $LINE"
    echo "  Logs:      $STATE_DIR/cron.log and $STATE_DIR/job-scan.log"
    echo "  Uninstall: bash $0 --uninstall"
    ;;
*)
    echo "Unsupported OS: $(uname -s). Schedule this manually: bash $SCAN_SCRIPT" >&2
    exit 1
    ;;
esac
