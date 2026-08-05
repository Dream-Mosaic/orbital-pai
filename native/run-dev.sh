#!/usr/bin/env bash
# Run the Flutter client in DEBUG mode — hot reload, assertions, the works.
#
#   ./run-dev.sh                 # first connected device (phone or emulator)
#   ./run-dev.sh <device-id>     # e.g. 41051FDJH000DM  (see: flutter devices)
#
# This is the everyday script. Use ./run-profile.sh instead when you are judging
# PERFORMANCE — a debug build is JIT-compiled with runtime shader compilation and
# live assertions, and can be several times slower than what you would ship.
#
# THE TUNNEL IS THE WHOLE POINT. config.dart points at 127.0.0.1, which on the
# device means the DEVICE's own loopback — not your Mac. `adb reverse` is what
# bridges the two. Without it the app looks broken in a specific, misleading way:
# the connection dot goes red and the webview panels load a blank error page,
# because BOTH are dialling a port with nothing behind it. `flutter run` on its
# own does not set the tunnel up; that is why this script exists.
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
  echo "No device. Plug one in (unlock it, accept the USB-debugging prompt) or" >&2
  echo "start an emulator, then re-run." >&2
  exit 1
fi

PORT=8787

# Dies on every unplug / emulator restart, so re-arm it every run. Target the
# device explicitly: with two attached, a bare `adb reverse` fails with
# "more than one device/emulator".
"$ADB" -s "$DEVICE" reverse --remove-all >/dev/null 2>&1 || true
"$ADB" -s "$DEVICE" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null

echo "▸ device:  $DEVICE"

# Trust nothing: prove the tunnel is actually registered before blaming the app.
if "$ADB" -s "$DEVICE" reverse --list 2>/dev/null | grep -q "tcp:$PORT"; then
  echo "▸ tunnel:  device:$PORT -> mac:$PORT  ✓"
else
  echo "▸ tunnel:  FAILED to register" >&2
  echo "⚠  Without it the app cannot reach the server at all: red connection dot," >&2
  echo "   blank nav panels. Try: $ADB -s $DEVICE reverse tcp:$PORT tcp:$PORT" >&2
fi

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "▸ server:  listening on :$PORT ✓"
else
  echo "⚠  Nothing is listening on :$PORT — start the server first (./dev.sh from the"
  echo "   repo root). Henry will come up with a RED connection dot until you do, and"
  echo "   the nav panels will open blank."
fi

cat <<EOF

── While it runs ──────────────────────────────────────────────────────────────
  r   hot reload            R   hot restart
  q   quit                  d   detach (leave the app running)

Screenshot, straight to a file — no Chrome, no Android Studio:
  ./shot.sh                 (writes shots/henry-NNN.png and prints the path)

A red connection dot means the socket could not reach the server. In order:
  1. is ./dev.sh running?
  2. did the tunnel line above say ✓?
  3. unplugged and replugged since? re-run this script — the tunnel dies with it.
───────────────────────────────────────────────────────────────────────────────

EOF

exec flutter run -d "$DEVICE"
