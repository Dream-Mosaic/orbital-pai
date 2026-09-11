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

PORT=8787

# The app reaches the Mac's Phoenix server over USB. This dies on every unplug, so re-arm it.
# Target the chosen device explicitly — with two devices attached (the script's own
# documented "Pixel as control, Lenovo as verdict" workflow), plain `adb reverse` fails
# with "more than one device/emulator".
"$ADB" -s "$DEVICE" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
echo "▸ device:  $DEVICE"
echo "▸ tunnel:  device:$PORT -> mac:$PORT"

if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "⚠  Nothing is listening on :$PORT — start the server first (./dev.sh from the repo root)." >&2
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

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet HEAD 2>/dev/null; then SHA="$SHA+"; fi
echo "▸ build:   $SHA"
echo "▸ target:  127.0.0.1:$PORT"

exec flutter run --profile -d "$DEVICE" --dart-define=BUILD_SHA="$SHA" \
  # localhost, NOT 127.0.0.1 -- see the note in run-dev.sh: the OIDC session cookie is keyed to
  # the host the app opened, and Authentik redirects back to OIDC_REDIRECT_URI's host.
  --dart-define=SERVER_HOST=localhost --dart-define=SERVER_PORT="$PORT"
