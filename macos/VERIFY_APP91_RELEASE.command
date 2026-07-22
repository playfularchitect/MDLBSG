#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo
  echo "APP 91 RELEASE VERIFICATION FAILED: $*" >&2
  exit 1
}

echo "============================================================"
echo "MDLBSG APP 91 — NON-DESTRUCTIVE RELEASE VERIFICATION"
echo "============================================================"
echo

APP=""
if [[ -d "/Applications/MDLBSG Compressor.app" ]]; then
  APP="/Applications/MDLBSG Compressor.app"
elif [[ -d "$HOME/Applications/MDLBSG Compressor.app" ]]; then
  APP="$HOME/Applications/MDLBSG Compressor.app"
else
  fail "MDLBSG Compressor.app was not found"
fi

PLIST="$APP/Contents/Info.plist"
MAIN="$APP/Contents/Resources/Scripts/main.scpt"
MENU_APP="$HOME/.mdlbsg/MDLBSG Menu.app"
MENU_PLIST="$MENU_APP/Contents/Info.plist"
MENU_MAIN="$MENU_APP/Contents/Resources/Scripts/main.scpt"
WRAPPER="$HOME/.mdlbsg/bin/mdlbsg"

[[ -f "$PLIST" ]] || fail "Compressor Info.plist is missing"
[[ -f "$MAIN" ]] || fail "compiled Compressor AppleScript is missing"
[[ -d "$MENU_APP" ]] || fail "native double-click menu application is missing"
[[ -f "$MENU_PLIST" ]] || fail "native menu Info.plist is missing"
[[ -f "$MENU_MAIN" ]] || fail "compiled native menu AppleScript is missing"
[[ -x "$WRAPPER" ]] || fail "command wrapper is missing"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$VERSION" == "91" ]] || fail "bundle version is $VERSION instead of 91"

MENU_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MENU_PLIST")"
[[ "$MENU_VERSION" == "91" ]] || fail "menu bundle version is $MENU_VERSION instead of 91"

MENU_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MENU_PLIST")"
[[ "$MENU_ID" == "com.mdlbsg.compressor.menu" ]] \
  || fail "menu bundle identifier is $MENU_ID"

MENU_AGENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$MENU_PLIST")"
[[ "$MENU_AGENT" == "true" ]] || fail "native menu is not configured as a UI agent"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app91-release-proof.XXXXXX")"
cleanup() {
  rm -f "$HOME/.mdlbsg/menu_app_self_test_request"
  rm -rf "$TMP"
}
trap cleanup EXIT

/usr/bin/osadecompile "$MAIN" > "$TMP/app91.applescript" \
  || fail "installed Compressor AppleScript could not be decompiled"

/usr/bin/osadecompile "$MENU_MAIN" > "$TMP/menu-app91.applescript" \
  || fail "installed native menu AppleScript could not be decompiled"

grep -Fq 'MDLBSG_SINGLE_LIVE_QUEUE_V88' "$TMP/app91.applescript" \
  || fail "App 88 queue marker is missing"
grep -Fq 'MDLBSG_MENU_CACHE_OPT_IN_V89' "$TMP/app91.applescript" \
  || fail "App 89 cache marker is missing"
grep -Fq 'MDLBSG_APPLET_RUN_HANDLER_FIX_V91' "$TMP/app91.applescript" \
  || fail "App 91 applet run-handler marker is missing"
grep -Fq 'mdlbsg_queue_submit.py' "$TMP/app91.applescript" \
  || fail "queue submission routing is missing"
grep -Fq 'MDLBSG Menu.app' "$TMP/app91.applescript" \
  || fail "native menu app launch routing is missing"

grep -Fq 'MDLBSG_NATIVE_MENU_APP_V91' "$TMP/menu-app91.applescript" \
  || fail "native menu marker is missing"
grep -Fq 'MDLBSG_CACHE_OPT_IN_MENU_V89' "$TMP/menu-app91.applescript" \
  || fail "launcher cache menu is missing"
grep -Fq 'activateIgnoringOtherApps' "$TMP/menu-app91.applescript" \
  || fail "frontmost activation is missing"
grep -Fq 'MDLBSG_APP91_MENU_APP_SELF_TEST_PASS' "$TMP/menu-app91.applescript" \
  || fail "native menu self-test marker is missing"

grep -Eq '^[[:space:]]*on run[[:space:]]*$' "$TMP/menu-app91.applescript" \
  || fail "native menu is missing its parameterless applet run handler"
if grep -Eq '^[[:space:]]*on run[[:space:]]+argv[[:space:]]*$' "$TMP/menu-app91.applescript"; then
  fail "native menu still contains the broken App 90 on run argv handler"
fi

MENU_PROOF="$TMP/menu-bundle-proof.txt"
/usr/bin/printf '%s' "$MENU_PROOF" > "$HOME/.mdlbsg/menu_app_self_test_request"
/usr/bin/open -n "$MENU_APP" \
  || fail "Launch Services rejected the native menu application"

MENU_PASS=NO
for _ in $(seq 1 80); do
  if [[ -f "$MENU_PROOF" ]] && \
     grep -Fq 'MDLBSG_APP91_MENU_APP_SELF_TEST_PASS' "$MENU_PROOF"
  then
    MENU_PASS=YES
    break
  fi
  sleep 0.1
done
[[ "$MENU_PASS" == "YES" ]] \
  || fail "native menu application did not execute through Launch Services"

rm -f "$HOME/.mdlbsg/menu_app_self_test_request"

grep -Fq 'CACHE_ENABLE_FILE="$HOME/.mdlbsg/cache_enabled"' "$WRAPPER" \
  || fail "cache opt-in marker is missing"
grep -Fq 'cache_on() { [ -f "$CACHE_ENABLE_FILE" ]; }' "$WRAPPER" \
  || fail "cache is not explicit opt-in"

CACHE_STATUS="$("$WRAPPER" cache status)"
[[ "$CACHE_STATUS" == *'cache: on'* || "$CACHE_STATUS" == *'cache: off'* ]] \
  || fail "cache status command failed"

/usr/bin/python3 - "$PLIST" "$MENU_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    with path.open("rb") as handle:
        plist = plistlib.load(handle)

    forbidden = {
        "NSAppleEventsUsageDescription",
        "NSAppleMusicUsageDescription",
        "NSCalendarsUsageDescription",
        "NSCameraUsageDescription",
        "NSContactsUsageDescription",
        "NSHomeKitUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSRemindersUsageDescription",
        "NSSiriUsageDescription",
        "NSSystemAdministrationUsageDescription",
    }
    remaining = sorted(forbidden.intersection(plist))
    if remaining:
        raise SystemExit(
            f"unused privacy keys remain in {path}: " + ", ".join(remaining)
        )
PY

[[ -x "$HOME/.mdlbsg/bin/mdlbsg_queue_submit.py" ]] \
  || fail "queue submitter is missing"
[[ -x "$HOME/.mdlbsg/bin/mdlbsg_queue_worker.py" ]] \
  || fail "queue worker is missing"

SUBMIT_TEST="$(/usr/bin/python3 "$HOME/.mdlbsg/bin/mdlbsg_queue_submit.py" --self-test)"
WORKER_TEST="$(/usr/bin/python3 "$HOME/.mdlbsg/bin/mdlbsg_queue_worker.py" --self-test)"

[[ "$SUBMIT_TEST" == *'MDLBSG_APP88_QUEUE_SUBMIT_SELF_TEST_PASS'* ]] \
  || fail "queue submitter self-test failed"
[[ "$WORKER_TEST" == *'MDLBSG_APP88_QUEUE_WORKER_SELF_TEST_PASS'* ]] \
  || fail "queue worker self-test failed"

/usr/bin/codesign --verify --strict "$APP" \
  || fail "local Compressor signature verification failed"
/usr/bin/codesign --verify --strict "$MENU_APP" \
  || fail "local native-menu signature verification failed"

echo "Compressor bundle version 91: PASS"
echo "native menu bundle version 91: PASS"
echo "native menu parameterless run handler: PASS"
echo "native menu Launch Services execution: PASS"
echo "native menu frontmost activation marker: PASS"
echo "compiled App 91 marker: PASS"
echo "compiled queue routing: PASS"
echo "cache policy explicit opt-in: PASS"
echo "current cache state: $(printf '%s\n' "$CACHE_STATUS" | head -n 1)"
echo "unused privacy metadata removed: PASS"
echo "queue submitter self-test: PASS"
echo "queue worker self-test: PASS"
echo "local code signatures: PASS"
echo
echo "Behavioral gate:"
echo "  1. Open MDLBSG Compressor ten separate times."
echo "  2. Close the menu after each open."
echo "  3. Confirm the menu appears in front every time."
echo "  4. Open Cache Settings and confirm the saved cache state is preserved."
echo "  5. Start one large compression and queue a second file."
echo "  6. Confirm one progress window and sequential completion."
