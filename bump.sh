#!/usr/bin/env bash
# Bump a version — the server and the app are released separately, so each has its own.
#
#   ./bump.sh server patch|minor|major   → server/priv/VERSION (read at runtime by App.version/0)
#   ./bump.sh app    patch|minor|major   → native/pubspec.yaml + kAppVersion in app_version.dart
#
# The server's version deliberately does NOT live in mix.exs: the Dockerfile's dependency layers
# are keyed on mix.exs, so bumping it there forced a cold Rust + EXLA rebuild on every deploy
# (issue #1). Both show in Settings ▸ About.
set -euo pipefail
cd "$(dirname "$0")"

usage() { echo "usage: $0 server|app patch|minor|major" >&2; exit 2; }
[ $# -eq 2 ] || usage
target=$1 part=$2

bump() {
  local cur=$1
  [[ $cur =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "not a plain X.Y.Z version: '$cur'" >&2; exit 1; }
  local ma=${BASH_REMATCH[1]} mi=${BASH_REMATCH[2]} pa=${BASH_REMATCH[3]}
  case $part in
    patch) echo "$ma.$mi.$((pa + 1))" ;;
    minor) echo "$ma.$((mi + 1)).0" ;;
    major) echo "$((ma + 1)).0.0" ;;
    *) usage ;;
  esac
}

case $target in
  server)
    file=server/priv/VERSION
    cur=$(tr -d '[:space:]' < "$file")
    next=$(bump "$cur")
    printf '%s\n' "$next" > "$file"
    ;;
  app)
    pubspec=native/pubspec.yaml
    dart=native/lib/app_version.dart
    cur=$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$pubspec")
    next=$(bump "$cur")
    sed -i.bak "s/^version:.*/version: $next/" "$pubspec"
    sed -i.bak "s/^const String kAppVersion = '.*';/const String kAppVersion = '$next';/" "$dart"
    rm -f "$pubspec.bak" "$dart.bak"
    grep -q "kAppVersion = '$next'" "$dart" || { echo "failed to update $dart" >&2; exit 1; }
    ;;
  *) usage ;;
esac

echo "$target $cur → $next"
