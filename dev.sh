#!/usr/bin/env bash
# Convenience delegator: run the Phoenix dev server from the repo root.
# The real script is server/dev.sh (it loads server/.env and tees to server/log/companion.log).
exec "$(dirname "$0")/server/dev.sh" "$@"
