#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="/Library/mac-wifi-troubleshooter"
PLIST_DIR="/Library/LaunchDaemons"
LOG_DIR="/Library/Logs/mac-wifi-troubleshooter"
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
command -v plutil >/dev/null 2>&1 || fail "plutil is not available; this script requires macOS."

for stream in "${STREAMS[@]}"; do
  source_plist="$ROOT/launchd/no.datamind.wifi-$stream.plist"
  [[ -f "$source_plist" ]] || fail "required plist is missing: $source_plist"
done

mkdir -p "$INSTALL_DIR" "$LOG_DIR"

for stream in "${STREAMS[@]}"; do
  label="no.datamind.wifi-$stream"
  if job_is_loaded "$label"; then
    launchctl bootout "system/$label" || fail "could not stop $label before reinstalling it."
  fi
done

cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/launchd" "$ROOT/config.sh" "$INSTALL_DIR/"
chown -R root:wheel "$INSTALL_DIR" "$LOG_DIR"
chmod -R go-w "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/launchd"
chmod 755 "$INSTALL_DIR"/bin/*.sh
chmod 700 "$LOG_DIR"

for stream in "${STREAMS[@]}"; do
  label="no.datamind.wifi-$stream"
  source_plist="$INSTALL_DIR/launchd/$label.plist"
  installed_plist="$PLIST_DIR/$label.plist"
  cp "$source_plist" "$installed_plist"
  chown root:wheel "$installed_plist"
  chmod 644 "$installed_plist"
  plutil -lint "$installed_plist" >/dev/null || fail "invalid launchd plist: $installed_plist"
  launchctl bootstrap system "$installed_plist" || fail "could not start $label; inspect the launchd/macOS logs."
done

printf 'Installed and started all Wi-Fi troubleshooters. Logs: %s\n' "$LOG_DIR"
