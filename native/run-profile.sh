#!/usr/bin/env bash
# Run the Flutter client in PROFILE mode — the only honest way to judge performance.
#
# Debug builds are JIT-compiled with shaders compiled at runtime and assertions live; they can be
# several times slower than what a user would actually get. Profile mode is AOT-compiled like a
# release build but keeps the tracing hooks DevTools needs, so it is the mode to measure in.
#
#   ./run-profile.sh                 # local server, first connected device
#   ./run-profile.sh --prod          # measure against the live server (real network latency)
#   ./run-profile.sh <device-id>     # e.g. 41051FDJH000DM  (see: flutter devices)
#
# NOTE: an emulator is NOT a valid perf target — its GPU behaviour says nothing about real
# hardware. Use the Pixel as a control and the Lenovo Tab as the verdict.
set -euo pipefail
cd "$(dirname "$0")"

DEFAULT_TARGET=local
source ./_target.sh
target_init "$@"

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

exec flutter run --profile -d "$DEVICE" "${DART_DEFINES[@]}"
