#!/usr/bin/env bash
# Dev runner for the voice companion.
#   ./dev.sh        (or: sh dev.sh)
#
# Loads .env (API keys + PORT), then runs the Phoenix server while mirroring ALL
# output to log/companion.log so it can be read without copy-paste.
set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck disable=SC1091
source .env
set +a

mkdir -p log
# Fresh log each run (the previous run is rotated to .prev), so it never balloons.
[ -f log/companion.log ] && mv -f log/companion.log log/companion.prev.log
echo "==== companion dev session $(date) ====" > log/companion.log

# Tee stdout+stderr to the log and the console at once.
exec mix phx.server 2>&1 | tee -a log/companion.log
