#!/bin/bash
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root: sudo $0" >&2
    exit 1
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: sudo $0" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/config.sh"

INSTALL_DIR=/Library/mac-wifi-troubleshooter
LOG_DIR=/Library/Logs/mac-wifi-troubleshooter
DAEMON_DIR=/Library/LaunchDaemons

for stream in ping state event; do
    plist="$ROOT/launchd/no.datamind.wifi-$stream.plist"
    if [ ! -f "$plist" ]; then
        echo "Missing plist: $plist. Restore it in the checkout and retry." >&2
        exit 1
    fi
    if ! plutil -lint "$plist"; then
        echo "Invalid plist: $plist. Fix it before installing." >&2
        exit 1
    fi
done

for stream in ping state event; do
    job="system/no.datamind.wifi-$stream"
    if launchctl bootout "$job"; then
        :
    else
        status=$?
        # launchctl returns ESRCH (3) when the job is not loaded.
        if [ "$status" -ne 3 ]; then
            echo "Cannot boot out $job (launchctl exit $status). Check sudo launchctl print $job and retry." >&2
            exit 1
        fi
    fi
done

mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$DAEMON_DIR"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/launchd" "$INSTALL_DIR/"
if [ -e "$INSTALL_DIR/config.sh" ]; then
    echo "Preserving installed config: $INSTALL_DIR/config.sh (checkout config is not copied)." >&2
else
    cp "$ROOT/config.sh" "$INSTALL_DIR/config.sh"
fi
chown -R root:wheel "$INSTALL_DIR" "$LOG_DIR"
chmod -R go-w "$INSTALL_DIR"
chmod 700 "$LOG_DIR"

for stream in ping state event; do
    plist="$DAEMON_DIR/no.datamind.wifi-$stream.plist"
    cp "$INSTALL_DIR/launchd/no.datamind.wifi-$stream.plist" "$plist"
    chown root:wheel "$plist"
    chmod 644 "$plist"
    if ! plutil -lint "$plist"; then
        echo "Invalid installed plist: $plist. Fix the checkout and rerun this script." >&2
        exit 1
    fi
done
for stream in ping state event; do
    plist="$DAEMON_DIR/no.datamind.wifi-$stream.plist"
    if ! launchctl bootstrap system "$plist"; then
        echo "Cannot bootstrap $plist. Check sudo launchctl print system/no.datamind.wifi-$stream and rerun this script." >&2
        exit 1
    fi
done
echo "Jobs installed and started. Boot jobs read $INSTALL_DIR/config.sh; logs go to $LOG_DIR."
