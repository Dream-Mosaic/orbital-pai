#!/usr/bin/env bash
# Run the Flutter client in DEBUG mode — hot reload, assertions, the works.
#
#   ./run-dev.sh                 # local server, first connected device
#   ./run-dev.sh --prod          # debug build pointed at PRODUCTION (see the warning below)
#   ./run-dev.sh <device-id>     # e.g. 41051FDJH000DM  (see: flutter devices)
#
# This is the everyday script. Use ./run-profile.sh when you are judging PERFORMANCE — a debug
# build is JIT-compiled with runtime shader compilation and live assertions, and can be several
# times slower than what you would ship. Use ./run-build.sh for a real release APK.
#
# --prod gives you hot reload and full logs against the live server. That is the point of it, and
# also the whole risk: every reminder you create, memory you write and email you send is REAL.
# Where the two targets are pointed, and how the tunnel is armed, lives in _target.sh.
set -euo pipefail
cd "$(dirname "$0")"

DEFAULT_TARGET=local
source ./_target.sh
target_init "$@"

cat <<'EOF'

── While it runs ──────────────────────────────────────────────────────────────
  r   hot reload            R   hot restart
  q   quit                  d   detach (leave the app running)

Screenshot, straight to a file — no Chrome, no Android Studio:
  ./shot.sh                 (writes shots/henry-NNN.png and prints the path)
EOF

# Target-specific, because the wrong checklist is worse than none: on --prod there is no ./dev.sh
# and no tunnel, and sending someone to look for them wastes the debugging round.
if [ "$TARGET" = local ]; then
  cat <<'EOF'

A red connection dot means the socket could not reach the server. In order:
  1. is ./dev.sh running?
  2. did the tunnel line above say ✓?
  3. unplugged and replugged since? re-run this script — the tunnel dies with it.
EOF
else
  cat <<'EOF'

You are on the LIVE server. Reminders, memories and emails are real.

A red connection dot here is the network or the deploy, not the tunnel. If the app drops to the
login screen it is because the stored token was for the other server — sign in again.
EOF
fi

cat <<'EOF'
───────────────────────────────────────────────────────────────────────────────

EOF

exec flutter run -d "$DEVICE" "${DART_DEFINES[@]}"
