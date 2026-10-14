#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/config.sh"
exec /usr/bin/perl "$ROOT/lib/logger.pl" merge "$@"
