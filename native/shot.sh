#!/usr/bin/env bash
# Grab a screenshot off the connected device — phone or emulator, same command.
#
#   ./shot.sh                    # -> shots/henry-001.png (auto-numbered)
#   ./shot.sh orb-listening      # -> shots/orb-listening.png
#   ./shot.sh /tmp/whatever.png  # an explicit path is used as-is
#   ./shot.sh -d <device-id> ... # pick a device when several are attached
#
# `adb exec-out` streams the PNG as raw bytes; plain `adb shell screencap` gets
# mangled by newline translation and lands as a corrupt file.
set -euo pipefail
cd "$(dirname "$0")"

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
if [ ! -x "$ADB" ]; then
  if command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
  else
    echo "No adb found (checked $HOME/Library/Android/sdk/platform-tools/adb and PATH)." >&2
    exit 1
  fi
fi

DEVICE=""
if [ "${1:-}" = "-d" ]; then
  DEVICE="${2:-}"
  shift 2
fi
if [ -z "$DEVICE" ]; then
  DEVICE="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [ -z "$DEVICE" ]; then
  echo "No device. Plug one in or start an emulator." >&2
  exit 1
fi

NAME="${1:-}"
if [ -z "$NAME" ]; then
  mkdir -p shots
  n=1
  while [ -e "$(printf 'shots/henry-%03d.png' "$n")" ]; do n=$((n + 1)); done
  OUT="$(printf 'shots/henry-%03d.png' "$n")"
elif [[ "$NAME" == *.png ]]; then
  OUT="$NAME"
  mkdir -p "$(dirname "$OUT")"
else
  mkdir -p shots
  OUT="shots/$NAME.png"
fi

"$ADB" -s "$DEVICE" exec-out screencap -p >"$OUT"

# screencap writes an empty file rather than failing when the screen is locked.
if [ ! -s "$OUT" ]; then
  rm -f "$OUT"
  echo "Got 0 bytes — is the screen on and unlocked?" >&2
  exit 1
fi

echo "$OUT  ($(du -h "$OUT" | cut -f1), $DEVICE)"
