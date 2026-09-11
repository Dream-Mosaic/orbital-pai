#!/usr/bin/env bash
# Build a RELEASE APK, install it, and launch it. This is the build you actually live with.
#
#   ./run-build.sh                 # production server (the default — see below)
#   ./run-build.sh --local         # release build against the Mac, for perf/behaviour comparisons
#   ./run-build.sh <device-id>     # e.g. 41051FDJH000DM  (see: flutter devices)
#
# Release mode is AOT-compiled with assertions stripped and no observatory, so there is no hot
# reload and no `flutter run` console. Watch it with:  adb logcat -s flutter:V
#
# ── Two things worth knowing before you run this ──────────────────────────────────────────────
#
# You cannot keep a dev build and a prod build side by side. Every build type shares the
# applicationId `com.orbital.pai`, so installing one REPLACES the other. Giving debug builds an
# applicationIdSuffix would fix that and break something worse: both apps would register the
# `orbital://` intent-filter, so every auth and connector return would pop the Android chooser —
# and the single-use login code would go to whichever app won. One app at a time is the safer
# trade for a two-user instance.
#
# Switching targets costs you a sign-in, not a reinstall. android/app/build.gradle.kts signs
# release with the DEBUG keystore, so `install -r` works in both directions and the token in
# secure storage survives. But that token is signed with the other server's SECRET_KEY_BASE: the
# socket is refused, /api/auth/session confirms a genuine 401, the token is cleared and you land
# on the login screen. That is the designed behaviour — an unreachable server, by contrast, must
# KEEP the token and retry.
set -euo pipefail
cd "$(dirname "$0")"

DEFAULT_TARGET=prod
source ./_target.sh
target_init "$@"

APK=build/app/outputs/flutter-apk/app-release.apk

case "$SHA" in
  *+) echo "⚠  Working tree is dirty — this APK is not any commit. Settings ▸ About will say $SHA." ;;
esac

echo
echo "▸ building release APK (a few minutes; AOT compilation is not fast)…"
flutter build apk --release "${DART_DEFINES[@]}"

[ -f "$APK" ] || _target_die "Build reported success but $APK is missing."
echo "▸ apk:     $APK ($(du -h "$APK" | cut -f1))"

echo "▸ installing onto ${DEVICE}…"
"$ADB" -s "$DEVICE" install -r "$APK"

"$ADB" -s "$DEVICE" shell am start -n com.orbital.pai/.MainActivity >/dev/null

cat <<EOF

▸ launched, pointed at $TARGET_HOST:$TARGET_PORT

If it opens on the login screen, that is expected whenever you have just switched targets — the
stored token belongs to the other server. Sign in again; the browser hands the app back a
single-use code and you are done.

  logs:        adb -s $DEVICE logcat -s flutter:V
  back to dev: ./run-dev.sh
EOF
