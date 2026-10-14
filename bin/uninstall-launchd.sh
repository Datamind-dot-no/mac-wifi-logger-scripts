#!/bin/bash
set -euo pipefail

INSTALL_DIR="/Library/mac-wifi-troubleshooter"
PLIST_DIR="/Library/LaunchDaemons"
STREAMS=(ping state event)

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

job_is_loaded() {
  local output
  if output="$(launchctl print "system/$1" 2>&1)"; then
    return 0
  fi
  if [[ "$output" == *"Could not find service"* ]]; then
    return 1
  fi
  fail "launchctl could not inspect system/$1: $output"
}

if [[ "${EUID}" -ne 0 ]]; then
  fail "run this script with sudo: sudo $0"
fi

command -v launchctl >/dev/null 2>&1 || fail "launchctl is not available; this script requires macOS."

if [[ ! -d "$INSTALL_DIR" ]]; then
  printf 'No installation found; captured logs, if any, are left untouched.\n'
  exit 0
fi

for stream in "${STREAMS[@]}"; do
  installed_plist="$PLIST_DIR/no.datamind.wifi-$stream.plist"
  [[ -f "$installed_plist" ]] || fail "installed plist is missing: $installed_plist; check the installation before retrying."
done

for stream in "${STREAMS[@]}"; do
  label="no.datamind.wifi-$stream"
  installed_plist="$PLIST_DIR/$label.plist"
  if job_is_loaded "$label"; then
    launchctl bootout "system/$label" || fail "could not stop $label; its plist was not removed."
  fi
  rm "$installed_plist" || fail "could not remove $installed_plist."
done

rm -rf "$INSTALL_DIR" || fail "could not remove installed files from $INSTALL_DIR."
printf 'Stopped and uninstalled all Wi-Fi troubleshooters. Captured logs were retained in /Library/Logs/mac-wifi-troubleshooter.\n'
