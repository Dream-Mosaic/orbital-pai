#!/usr/bin/env bash
# Run the Flutter client in PROFILE mode — the only honest way to judge performance.
#
# Debug builds are JIT-compiled with shaders compiled at runtime and assertions live; they can be
# several times slower than what a user would actually get. Profile mode is AOT-compiled like a
# release build but keeps the tracing hooks DevTools needs, so it is the mode to measure in.
#
#   ./run-profile.sh                 # first connected device
#   ./run-profile.sh <device-id>     # e.g. 41051FDJH000DM  (see: flutter devices)
#
# NOTE: an emulator is NOT a valid perf target — its GPU behaviour says nothing about real hardware.
# Use the Pixel as a control and the Lenovo Tab as the verdict.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/flutter/bin:$PATH"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
if [ ! -x "$ADB" ]; then
  if command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
  else
    echo "No adb found (checked $HOME/Library/Android/sdk/platform-tools/adb and PATH)." >&2
    exit 1
  fi
fi

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [ -z "$DEVICE" ]; then
  echo "No device. Plug one in, unlock it, accept the USB-debugging prompt." >&2
  exit 1
fi

# The app reaches the Mac's Phoenix server over USB. This dies on every unplug, so re-arm it.
# Target the chosen device explicitly — with two devices attached (the script's own
# documented "Pixel as control, Lenovo as verdict" workflow), plain `adb reverse` fails
# with "more than one device/emulator".
"$ADB" -s "$DEVICE" reverse tcp:8787 tcp:8787 >/dev/null
echo "▸ device:  $DEVICE"
echo "▸ tunnel:  device:8787 -> mac:8787"

if ! lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "⚠  Nothing is listening on :8787 — start the server first (./dev.sh from the repo root)." >&2
fi

cat <<'EOF'

── What to watch ──────────────────────────────────────────────────────────────
Open the DevTools link this prints, go to the Performance tab, and watch the
RASTER thread (not the UI thread) — the orb's cost is painting, not layout.

The signature that matters: smooth while idle/off, but stuttering specifically
while LISTENING or SPEAKING, and worse the LOUDER you talk. That is the five
per-frame blur passes, and it means the mitigations are needed
(docs/superpowers/specs/2026-07-25-meridian-orb-futures.md §1b, §1c).

Also check: with the mic OFF, does the raster thread still show steady per-frame
work? If yes, the 24/7 wall-power lever isn't there yet.
───────────────────────────────────────────────────────────────────────────────

EOF

exec flutter run --profile -d "$DEVICE"
