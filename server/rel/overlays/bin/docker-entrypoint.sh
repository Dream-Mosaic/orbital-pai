#!/bin/sh
# Container entrypoint: prepare the SQLite volume, run migrations, then boot the server.
set -eu

# DATABASE_PATH points at a file on a Coolify persistent volume (e.g. /data/app.db).
# Make sure its directory exists before Ecto tries to open/create the DB file.
if [ -n "${DATABASE_PATH:-}" ]; then
  mkdir -p "$(dirname "$DATABASE_PATH")"
fi

# Apply any pending migrations (idempotent), then start Phoenix.
/app/bin/migrate
exec /app/bin/server
