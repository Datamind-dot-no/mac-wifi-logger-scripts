#!/bin/bash
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root: sudo $0" >&2
    exit 1
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: sudo $0 (captured logs are retained)" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/config.sh"

failed=0
for stream in ping state event; do
    job="system/no.datamind.wifi-$stream"
    if launchctl bootout "$job"; then
        :
    else
        status=$?
        # launchctl returns ESRCH (3) when the job is not loaded.
        if [ "$status" -ne 3 ]; then
            echo "Cannot boot out $job (launchctl exit $status). Check sudo launchctl print $job and retry." >&2
            failed=1
            continue
        fi
    fi
    rm -f "/Library/LaunchDaemons/no.datamind.wifi-$stream.plist"
done
if [ "$failed" -ne 0 ]; then
    echo "Install tree retained because some jobs could not be stopped. Resolve the errors and rerun this script." >&2
    exit 1
fi
rm -Rf /Library/mac-wifi-troubleshooter
echo "Jobs uninstalled. Captured logs retained in /Library/Logs/mac-wifi-troubleshooter."
