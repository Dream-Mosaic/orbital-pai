#!/usr/bin/env bash
# Sourced by run-dev.sh / run-profile.sh / run-build.sh — never executed on its own.
#
# ONE place decides where a build points, arms the USB tunnel, and prints the banner.
#
# It exists because that logic was copy-pasted per script and drifted, twice in one week:
# run-profile.sh's banner still advertised 127.0.0.1 long after run-dev.sh moved to localhost,
# and a comment written BETWEEN two `\` continuations commented out the rest of the joined line,
# silently dropping both --dart-defines so a "dev" run pointed at production. The cure for both
# is structural: the banner is printed from the same variables the build consumes, so it cannot
# describe a build that was not made.
#
# Caller contract:
#   DEFAULT_TARGET=local            # or prod — what this script points at with no flag
#   source "$(dirname "$0")/_target.sh"
#   target_init "$@"                # parses --local/--prod/<device-id>
#   exec flutter run -d "$DEVICE" "${DART_DEFINES[@]}"
#
# Sets, for the caller: ADB, DEVICE, TARGET, TARGET_HOST, TARGET_PORT, SHA, DART_DEFINES (array).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "_target.sh is a library — source it from run-dev.sh / run-profile.sh / run-build.sh." >&2
  exit 1
fi

_TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_target_die() { echo "$@" >&2; exit 1; }

# The local server. Matches PORT in server/.env; `./dev.sh` from the repo root serves it.
#
# localhost, NOT 127.0.0.1 — they are different COOKIE hosts even on one machine. The session
# holding :oidc_state is stored against whichever name the app opened, Authentik returns to
# whichever OIDC_REDIRECT_URI names, and a mismatch loses the cookie: "state mismatch" on an
# otherwise perfect login. `adb reverse` serves both names, so only the string has to agree.
LOCAL_HOST=localhost
LOCAL_PORT=8787

# Production is READ OUT OF lib/server_config.dart rather than repeated here. Those defaults are
# what a bare `flutter build apk --release` ships, so parsing them keeps this script honest about
# the thing it is meant to verify — and makes a divergence impossible rather than merely unlikely.
_target_prod_defaults() {
  local flat
  flat="$(tr '\n' ' ' < "$_TARGET_DIR/lib/server_config.dart")" \
    || _target_die "Cannot read lib/server_config.dart."
  PROD_HOST="$(printf '%s' "$flat" |
    sed -n "s/.*fromEnvironment('SERVER_HOST'[^)]*defaultValue: *'\([^']*\)').*/\1/p")"
  PROD_PORT="$(printf '%s' "$flat" |
    sed -n "s/.*fromEnvironment('SERVER_PORT'[^)]*defaultValue: *\([0-9]*\)).*/\1/p")"
  [ -n "$PROD_HOST" ] && [ -n "$PROD_PORT" ] || _target_die \
    "Could not read the production host/port defaults out of lib/server_config.dart.
Its shape changed; fix _target_prod_defaults in _target.sh rather than hardcoding them here."
}

_target_find_adb() {
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
  if [ ! -x "$ADB" ]; then
    command -v adb >/dev/null 2>&1 \
      || _target_die "No adb found (checked $HOME/Library/Android/sdk/platform-tools/adb and PATH)."
    ADB="$(command -v adb)"
  fi
}

target_init() {
  export PATH="$HOME/flutter/bin:$PATH"
  _target_find_adb

  TARGET="${DEFAULT_TARGET:?target_init: set DEFAULT_TARGET=local|prod before sourcing}"
  DEVICE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prod)  TARGET=prod ;;
      --local) TARGET=local ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      -*) _target_die "Unknown flag: $1  (expected --prod, --local, or a device id)" ;;
      *)  DEVICE="$1" ;;
    esac
    shift
  done

  if [ -z "$DEVICE" ]; then
    DEVICE="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  fi
  [ -n "$DEVICE" ] || _target_die \
    "No device. Plug one in (unlock it, accept the USB-debugging prompt) or start an emulator."

  if [ "$TARGET" = prod ]; then
    _target_prod_defaults
    TARGET_HOST="$PROD_HOST"
    TARGET_PORT="$PROD_PORT"
  else
    TARGET_HOST="$LOCAL_HOST"
    TARGET_PORT="$LOCAL_PORT"
  fi

  # The build stamp. `kAppVersion` is a hand-bumped constant and says nothing about which commit
  # is on the device — a build 33 commits stale looks identical to a current one in the UI, which
  # has already cost one debugging round chasing a "missing" feature that had in fact shipped.
  # Settings ▸ About shows this next to the server's version. `+` means the tree was dirty.
  SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  git diff --quiet HEAD 2>/dev/null || SHA="$SHA+"

  DART_DEFINES=(
    "--dart-define=BUILD_SHA=$SHA"
    "--dart-define=SERVER_HOST=$TARGET_HOST"
    "--dart-define=SERVER_PORT=$TARGET_PORT"
  )

  echo "▸ device:  $DEVICE"
  echo "▸ build:   $SHA"
  echo "▸ target:  $TARGET_HOST:$TARGET_PORT  ($TARGET)"

  if [ "$TARGET" = local ]; then
    _target_arm_tunnel
  else
    _target_probe_prod
  fi
}

# The app reaches the Mac's Phoenix server over USB. Dies on every unplug / emulator restart, so
# re-arm it every run; `flutter run` does not do this for you, which is why these scripts exist.
# Target the device explicitly — with two attached, a bare `adb reverse` fails with "more than one
# device/emulator", and the two-device setup is the documented perf workflow.
_target_arm_tunnel() {
  "$ADB" -s "$DEVICE" reverse --remove-all >/dev/null 2>&1 || true
  "$ADB" -s "$DEVICE" reverse "tcp:$TARGET_PORT" "tcp:$TARGET_PORT" >/dev/null

  # Trust nothing: prove the mapping registered before blaming the app.
  if "$ADB" -s "$DEVICE" reverse --list 2>/dev/null | grep -q "tcp:$TARGET_PORT"; then
    echo "▸ tunnel:  device:$TARGET_PORT -> mac:$TARGET_PORT  ✓"
  else
    echo "▸ tunnel:  FAILED to register" >&2
    echo "⚠  Without it the app cannot reach the server at all: red connection dot, blank nav" >&2
    echo "   panels. Try: $ADB -s $DEVICE reverse tcp:$TARGET_PORT tcp:$TARGET_PORT" >&2
  fi

  if lsof -nP -iTCP:"$TARGET_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "▸ server:  listening on :$TARGET_PORT ✓"
  else
    echo "⚠  Nothing is listening on :$TARGET_PORT — start the server first (./dev.sh from the"
    echo "   repo root). The app will come up with a RED connection dot until you do, and the"
    echo "   nav panels will open blank."
  fi
}

# The prod equivalent of the lsof check: is anything actually answering? /api/auth/session with no
# bearer token is the cheapest honest probe — a reachable server returns 401, which means both TLS
# and the API pipeline are alive. Advisory only: a flaky laptop network is not a reason to refuse
# to build, and the phone may have connectivity the Mac does not.
_target_probe_prod() {
  local scheme=http code
  # Written as an if, not `[ ... ] && scheme=https`: under `set -e` a false test makes the whole
  # && list return 1, which aborts the script. Same rule as secureForPort() on the Dart side —
  # TLS is inferred from the port, never configured as a second knob that could disagree.
  if [ "$TARGET_PORT" = 443 ]; then scheme=https; fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 6 \
    "$scheme://$TARGET_HOST:$TARGET_PORT/api/auth/session" 2>/dev/null || echo 000)"
  case "$code" in
    401) echo "▸ server:  $TARGET_HOST answering ✓" ;;
    000) echo "⚠  No answer from $TARGET_HOST (from THIS Mac). The phone may still reach it." ;;
    *)   echo "⚠  $TARGET_HOST answered $code, expected 401 — is that the right host?" ;;
  esac
}
