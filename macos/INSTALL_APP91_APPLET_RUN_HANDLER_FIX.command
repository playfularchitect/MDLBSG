#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

SOURCE="$HERE/MDLBSG_CompressorWindow.applescript"
WRAPPER_SOURCE="$HERE/mdlbsg"
MENU_SOURCE="$HERE/src/launcher_menu_app91.applescript"
APP86_INSTALLER="$HERE/INSTALL_APP86_REENTRANT_DISPATCHER.command"
APP86_BASE_SOURCE="$HERE/src/MDLBSG_CompressorWindow_APP86_PREREQUISITE.applescript"
CONFIGURE_APP="$HERE/configure_app.py"

SUBMIT_SOURCE="$HERE/src/mdlbsg_queue_submit.py"
WORKER_SOURCE="$HERE/src/mdlbsg_queue_worker.py"
RESULTS_SOURCE="$HERE/src/results_dialog_app88.applescript"

BIN="$HOME/.mdlbsg/bin"

fail() {
  echo
  echo "APP 91 INSTALL FAILED: $*" >&2
  exit 1
}

echo "============================================================"
echo "MDLBSG APP 91 — APPLET RUN-HANDLER FIX INSTALLER"
echo "============================================================"
echo

for path in \
  "$SOURCE" \
  "$WRAPPER_SOURCE" \
  "$MENU_SOURCE" \
  "$APP86_INSTALLER" \
  "$APP86_BASE_SOURCE" \
  "$CONFIGURE_APP" \
  "$SUBMIT_SOURCE" \
  "$WORKER_SOURCE" \
  "$RESULTS_SOURCE"
do
  [[ -f "$path" ]] \
    || fail "missing required file: $path"
done

grep -Fq \
  'MDLBSG_SINGLE_LIVE_QUEUE_V88' \
  "$SOURCE" \
  || fail "App 88 queue source marker is missing"

grep -Fq \
  'mdlbsg_queue_submit.py' \
  "$SOURCE" \
  || fail "queue submit routing is missing"

grep -Fq \
  'MDLBSG_MENU_CACHE_OPT_IN_V89' \
  "$SOURCE" \
  || fail "App 89 cache-menu marker is missing"

grep -Fq \
  'MDLBSG_APPLET_RUN_HANDLER_FIX_V91' \
  "$SOURCE" \
  || fail "App 91 applet run-handler marker is missing"

grep -Fq \
  'MDLBSG_NATIVE_MENU_APP_V91' \
  "$MENU_SOURCE" \
  || fail "App 91 native menu marker is missing"

# A Finder-launched AppleScript applet receives a parameterless run event.
# `on run argv` is valid for osascript command-line execution, but it is the
# exact App 90 failure: the applet launch could not coerce the run event to argv.
grep -Eq '^[[:space:]]*on run[[:space:]]*$' "$MENU_SOURCE" \
  || fail "native menu source is missing a parameterless run handler"

if grep -Eq '^[[:space:]]*on run[[:space:]]+argv[[:space:]]*$' "$MENU_SOURCE"; then
  fail "native menu source still contains the broken on run argv handler"
fi

grep -Fq \
  'CACHE_ENABLE_FILE=' \
  "$WRAPPER_SOURCE" \
  || fail "opt-in cache wrapper is missing"

echo "[1/8] Installing the proven MDLBSG core and helpers..."
echo

# App 86 validates that its original worker dispatch is present.
# App 88 intentionally replaces that dispatch, so run App 86 from
# an isolated temporary package containing the pristine App 86 source.
(
  set -euo pipefail

  PREREQ_STAGE="$(
    mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app91-app86-prereq.XXXXXX"
  )"

  cleanup_prerequisite() {
    rm -rf "$PREREQ_STAGE"
  }
  trap cleanup_prerequisite EXIT

  PREREQ_PACKAGE="$PREREQ_STAGE/App86Prerequisite"

  /usr/bin/ditto \
    "$HERE" \
    "$PREREQ_PACKAGE"

  cp \
    "$APP86_BASE_SOURCE" \
    "$PREREQ_PACKAGE/MDLBSG_CompressorWindow.applescript"

  grep -Fq \
    'MDLBSG_REENTRANT_DISPATCHER_V86' \
    "$PREREQ_PACKAGE/MDLBSG_CompressorWindow.applescript"

  grep -Fq \
    'mdlbsg_ui_worker.py' \
    "$PREREQ_PACKAGE/MDLBSG_CompressorWindow.applescript"

  if grep -Fq \
    'MDLBSG_SINGLE_LIVE_QUEUE_V88' \
    "$PREREQ_PACKAGE/MDLBSG_CompressorWindow.applescript"
  then
    echo "APP 91 INSTALL FAILED: prerequisite staging contains App 88-or-later queue source." >&2
    exit 1
  fi

  chmod +x \
    "$PREREQ_PACKAGE/INSTALL_APP86_REENTRANT_DISPATCHER.command"

  /bin/bash \
    "$PREREQ_PACKAGE/INSTALL_APP86_REENTRANT_DISPATCHER.command"
)

echo
echo "[2/8] Stopping older queue experiments..."

pkill -TERM -f \
  "$HOME/.mdlbsg/bin/mdlbsg_queue_worker.py" \
  2>/dev/null || true

pkill -TERM -f \
  "$HOME/.mdlbsg/bin/mdlbsg_ui_worker.py" \
  2>/dev/null || true

pkill -TERM -f \
  "$HOME/.mdlbsg/bin/mdlbsg_progress_window" \
  2>/dev/null || true


pkill -TERM -f \
  "$HOME/[.]mdlbsg/MDLBSG Menu[.]app/Contents/MacOS/applet( |$)" \
  2>/dev/null || true

pkill -TERM -f \
  '^/usr/bin/osascript .*[/]launcher_dialog[.]applescript' \
  2>/dev/null || true

for executable in droplet applet; do
  pkill -TERM -f \
    "/MDLBSG Compressor.app/Contents/MacOS/${executable}" \
    2>/dev/null || true
done

sleep 1

pkill -KILL -f \
  "$HOME/.mdlbsg/bin/mdlbsg_queue_worker.py" \
  2>/dev/null || true

rm -rf \
  "$HOME/.mdlbsg/queue" \
  "$HOME/.mdlbsg/queue88"

echo "      old queue processes: STOPPED"
echo "      stale queue state: CLEARED"

echo
echo "[3/8] Installing and self-testing the queue runtime..."

mkdir -p "$BIN"

cp "$SUBMIT_SOURCE" \
  "$BIN/mdlbsg_queue_submit.py"

cp "$WORKER_SOURCE" \
  "$BIN/mdlbsg_queue_worker.py"

chmod +x \
  "$BIN/mdlbsg_queue_submit.py" \
  "$BIN/mdlbsg_queue_worker.py"

/usr/bin/python3 \
  -m py_compile \
  "$BIN/mdlbsg_queue_submit.py" \
  "$BIN/mdlbsg_queue_worker.py" \
  || fail "queue Python syntax test failed"

SUBMIT_TEST="$(
  /usr/bin/python3 \
    "$BIN/mdlbsg_queue_submit.py" \
    --self-test
)"

WORKER_TEST="$(
  /usr/bin/python3 \
    "$BIN/mdlbsg_queue_worker.py" \
    --self-test
)"

[[ "$SUBMIT_TEST" == \
   *'MDLBSG_APP88_QUEUE_SUBMIT_SELF_TEST_PASS'* ]] \
  || fail "queue submitter self-test failed"

[[ "$WORKER_TEST" == \
   *'MDLBSG_APP88_QUEUE_WORKER_SELF_TEST_PASS'* ]] \
  || fail "queue worker self-test failed"

echo "      queue Python syntax: PASS"
echo "      queue submitter self-test: PASS"
echo "      queue worker self-test: PASS"

echo
echo "[4/8] Installing and self-testing the native menu app and opt-in cache wrapper..."
echo

mkdir -p "$HOME/.mdlbsg" "$BIN"

cp "$WRAPPER_SOURCE" "$BIN/mdlbsg"
chmod +x "$BIN/mdlbsg"

grep -Fq \
  'CACHE_ENABLE_FILE="$HOME/.mdlbsg/cache_enabled"' \
  "$BIN/mdlbsg" \
  || fail "installed wrapper is missing explicit cache opt-in"

grep -Fq \
  'cache_on() { [ -f "$CACHE_ENABLE_FILE" ]; }' \
  "$BIN/mdlbsg" \
  || fail "installed wrapper still uses implicit cache enablement"

MENU_APP="$HOME/.mdlbsg/MDLBSG Menu.app"

(
  set -euo pipefail

  MENU_STAGE_ROOT="$(
    mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app91-menu-stage.XXXXXX"
  )"

  cleanup_menu_stage() {
    rm -rf "$MENU_STAGE_ROOT"
  }
  trap cleanup_menu_stage EXIT

  MENU_STAGE="$MENU_STAGE_ROOT/MDLBSG Menu.app"
  MENU_TEXT="$MENU_STAGE_ROOT/menu-app91.applescript"

  /usr/bin/osacompile \
    -o "$MENU_STAGE" \
    "$MENU_SOURCE" \
    || fail "App 91 native menu application did not compile"

  python3 \
    "$CONFIGURE_APP" \
    "$MENU_STAGE" \
    "com.mdlbsg.compressor.menu" \
    "MDLBSG Menu" \
    --bundle-version 91 \
    --agent \
    || fail "native menu bundle identity configuration failed"

  if [[ -f "$HERE/icons/Compressor.icns" ]]; then
    cp \
      "$HERE/icons/Compressor.icns" \
      "$MENU_STAGE/Contents/Resources/applet.icns"
  fi

  xattr -cr "$MENU_STAGE" 2>/dev/null || true

  /usr/bin/codesign \
    --force \
    --sign - \
    "$MENU_STAGE" \
    || fail "native menu application signing failed"

  /usr/bin/codesign \
    --verify \
    --strict \
    "$MENU_STAGE" \
    || fail "staged native menu signature verification failed"

  /usr/bin/osadecompile \
    "$MENU_STAGE/Contents/Resources/Scripts/main.scpt" \
    > "$MENU_TEXT" \
    || fail "compiled native menu could not be inspected"

  grep -Fq \
    'MDLBSG_NATIVE_MENU_APP_V91' \
    "$MENU_TEXT" \
    || fail "compiled native menu lost its App 91 marker"

  grep -Fq \
    'MDLBSG_CACHE_OPT_IN_MENU_V89' \
    "$MENU_TEXT" \
    || fail "compiled native menu lost cache settings"

  grep -Fq \
    'activateIgnoringOtherApps' \
    "$MENU_TEXT" \
    || fail "compiled native menu lost frontmost activation"

  grep -Eq '^[[:space:]]*on run[[:space:]]*$' "$MENU_TEXT" \
    || fail "compiled native menu lost the parameterless run handler"

  if grep -Eq '^[[:space:]]*on run[[:space:]]+argv[[:space:]]*$' "$MENU_TEXT"; then
    fail "compiled native menu still contains the broken on run argv handler"
  fi

  /usr/bin/python3 - "$MENU_STAGE/Contents/Info.plist" <<'PYMENU'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as handle:
    plist = plistlib.load(handle)

expected = {
    "CFBundleIdentifier": "com.mdlbsg.compressor.menu",
    "CFBundleVersion": "91",
    "LSUIElement": True,
}

for key, value in expected.items():
    if plist.get(key) != value:
        raise SystemExit(
            f"native menu plist mismatch: {key}={plist.get(key)!r}, expected {value!r}"
        )
PYMENU

  rm -rf "$MENU_APP"
  mv "$MENU_STAGE" "$MENU_APP"
)

# Remove the old bare-script helper so App 91 cannot silently fall back to it.
rm -f \
  "$HOME/.mdlbsg/launcher_dialog.applescript" \
  "$HOME/.mdlbsg/menu_app_self_test_request" \
  "$HOME/.mdlbsg/menu_app_self_test_result"

[[ -d "$MENU_APP" ]] \
  || fail "native menu application is missing after installation"

LSREGISTER_MENU="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER_MENU" ]]; then
  "$LSREGISTER_MENU" -f "$MENU_APP" >/dev/null 2>&1 || true
fi

# Do not invoke this applet source with osascript arguments. App 90 did that,
# which masked the fact that a Finder applet launch supplies no argv list.
grep -Eq '^[[:space:]]*on run[[:space:]]*$' "$MENU_SOURCE" \
  || fail "native menu parameterless run-handler proof failed"

MENU_BUNDLE_PROOF="$(mktemp "${TMPDIR:-/tmp}/mdlbsg-app91-menu-proof.XXXXXX")"
rm -f "$MENU_BUNDLE_PROOF"

/usr/bin/printf '%s' \
  "$MENU_BUNDLE_PROOF" \
  > "$HOME/.mdlbsg/menu_app_self_test_request"

/usr/bin/open -n "$MENU_APP" \
  || fail "Launch Services rejected the native menu application"

MENU_BUNDLE_PASS=NO
for _ in $(seq 1 80); do
  if [[ -f "$MENU_BUNDLE_PROOF" ]] && \
     grep -Fq 'MDLBSG_APP91_MENU_APP_SELF_TEST_PASS' "$MENU_BUNDLE_PROOF"
  then
    MENU_BUNDLE_PASS=YES
    break
  fi
  sleep 0.1
done

rm -f \
  "$HOME/.mdlbsg/menu_app_self_test_request" \
  "$MENU_BUNDLE_PROOF"

[[ "$MENU_BUNDLE_PASS" == "YES" ]] \
  || fail "native menu application did not execute through Launch Services"

CACHE_STATUS="$("$BIN/mdlbsg" cache status)"
[[ "$CACHE_STATUS" == *'cache: on'* || "$CACHE_STATUS" == *'cache: off'* ]] \
  || fail "cache status command failed"

echo "      native menu bundle: INSTALLED"
echo "      parameterless applet run handler: PASS"
echo "      Launch Services execution: PASS"
echo "      frontmost activation marker: PASS"
echo "      cache policy: explicit opt-in"
echo "      current cache state: $(printf '%s\n' "$CACHE_STATUS" | head -n 1)"

echo
echo "[5/8] Compile-testing the App 91 droplet..."

STAGE_ROOT="$(
  mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app91-stage.XXXXXX"
)"

cleanup() {
  rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

TEST_APP="$STAGE_ROOT/App91 Source Test.app"
TEST_TEXT="$STAGE_ROOT/app91-source-test.applescript"

/usr/bin/osacompile \
  -o "$TEST_APP" \
  "$SOURCE" \
  || fail "App 91 AppleScript did not compile"

/usr/bin/osadecompile \
  "$TEST_APP/Contents/Resources/Scripts/main.scpt" \
  > "$TEST_TEXT" \
  || fail "compiled App 91 source could not be inspected"

grep -Fq \
  'MDLBSG_SINGLE_LIVE_QUEUE_V88' \
  "$TEST_TEXT" \
  || fail "compiled source lost the App 88 marker"

grep -Fq \
  'mdlbsg_queue_submit.py' \
  "$TEST_TEXT" \
  || fail "compiled source lost queue routing"

grep -Fq \
  'MDLBSG_MENU_CACHE_OPT_IN_V89' \
  "$TEST_TEXT" \
  || fail "compiled source lost the App 89 cache marker"

grep -Fq \
  'MDLBSG_APPLET_RUN_HANDLER_FIX_V91' \
  "$TEST_TEXT" \
  || fail "compiled source lost the App 91 applet run-handler marker"

grep -Fq \
  'MDLBSG Menu.app' \
  "$TEST_TEXT" \
  || fail "compiled source lost native menu app launching"

echo "      AppleScript compile: PASS"
echo "      queue routing in compiled source: PASS"

echo
echo "[6/8] Building and installing the final App 91 bundle..."

FINAL_STAGE="$STAGE_ROOT/MDLBSG Compressor.app"

/usr/bin/osacompile \
  -o "$FINAL_STAGE" \
  "$SOURCE" \
  || fail "final App 91 bundle did not compile"

python3 \
  "$CONFIGURE_APP" \
  "$FINAL_STAGE" \
  "com.mdlbsg.compressor" \
  "MDLBSG Compressor" \
  --bundle-version 91 \
  || fail "App 91 bundle identity configuration failed"

if [[ -f "$HERE/icons/Compressor.icns" ]]; then
  cp \
    "$HERE/icons/Compressor.icns" \
    "$FINAL_STAGE/Contents/Resources/droplet.icns"
fi

xattr -cr \
  "$FINAL_STAGE" \
  2>/dev/null || true

/usr/bin/codesign \
  --force \
  --sign - \
  "$FINAL_STAGE" \
  || fail "App 91 signing failed"

/usr/bin/codesign \
  --verify \
  --strict \
  "$FINAL_STAGE" \
  || fail "staged App 91 signature verification failed"

if [[ -d "/Applications/MDLBSG Compressor.app" ]]; then
  APPDIR="/Applications"
elif [[ -d "$HOME/Applications/MDLBSG Compressor.app" ]]; then
  APPDIR="$HOME/Applications"
elif [[ -w "/Applications" ]]; then
  APPDIR="/Applications"
else
  APPDIR="$HOME/Applications"
  mkdir -p "$APPDIR"
fi

FINAL_APP="$APPDIR/MDLBSG Compressor.app"

if [[ -d "$FINAL_APP" ]]; then
  BACKUP="$HOME/Downloads/MDLBSG_Compressor_before_App91_$(date '+%Y%m%d_%H%M%S').app"

  cp -R \
    "$FINAL_APP" \
    "$BACKUP"

  echo "      previous app backup:"
  echo "      $BACKUP"
fi

rm -rf "$FINAL_APP"
mv "$FINAL_STAGE" "$FINAL_APP"

echo
echo "[7/8] Installing the icon-aware results helper..."

mkdir -p "$HOME/.mdlbsg"

RESULTS_HELPER="$HOME/.mdlbsg/results_dialog.applescript"
RESULTS_ICON="$HOME/.mdlbsg/MDLBSG_Compressor_Results.icns"
RESULTS_ICON_PATH="$HOME/.mdlbsg/results_icon_path"

cp \
  "$RESULTS_SOURCE" \
  "$RESULTS_HELPER"

chmod 644 "$RESULTS_HELPER"

APP_ICON="$FINAL_APP/Contents/Resources/droplet.icns"

[[ -f "$APP_ICON" ]] \
  || fail "the installed Compressor icon is missing"

cp "$APP_ICON" "$RESULTS_ICON"
chmod 644 "$RESULTS_ICON"

/usr/bin/printf '%s' \
  "$RESULTS_ICON" \
  > "$RESULTS_ICON_PATH"

grep -Fq \
  'MDLBSG_RESULTS_COMPRESSOR_ICON_APP88' \
  "$RESULTS_HELPER" \
  || fail "results helper lost its icon marker"

echo "      results helper: INSTALLED"
echo "      Compressor icon: INSTALLED"

echo
echo "[8/8] Final installed-build proof..."

INSTALLED_TEXT="$STAGE_ROOT/installed-app91.applescript"

/usr/bin/osadecompile \
  "$FINAL_APP/Contents/Resources/Scripts/main.scpt" \
  > "$INSTALLED_TEXT" \
  || fail "installed app could not be inspected"

grep -Fq \
  'MDLBSG_SINGLE_LIVE_QUEUE_V88' \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the App 88 marker"

grep -Fq \
  'mdlbsg_queue_submit.py' \
  "$INSTALLED_TEXT" \
  || fail "installed app lost queue routing"


grep -Fq \
  'MDLBSG_MENU_CACHE_OPT_IN_V89' \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the App 89 cache marker"

grep -Fq \
  'MDLBSG_APPLET_RUN_HANDLER_FIX_V91' \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the App 91 applet run-handler marker"

grep -Fq \
  'MDLBSG Menu.app' \
  "$INSTALLED_TEXT" \
  || fail "installed app lost native menu app launching"

[[ -d "$HOME/.mdlbsg/MDLBSG Menu.app" ]] \
  || fail "installed native menu application is missing"

MENU_INSTALLED_TEXT="$STAGE_ROOT/installed-menu-app91.applescript"
/usr/bin/osadecompile \
  "$HOME/.mdlbsg/MDLBSG Menu.app/Contents/Resources/Scripts/main.scpt" \
  > "$MENU_INSTALLED_TEXT" \
  || fail "installed native menu application could not be inspected"

grep -Fq \
  'MDLBSG_NATIVE_MENU_APP_V91' \
  "$MENU_INSTALLED_TEXT" \
  || fail "installed native menu lost its App 91 marker"

grep -Fq \
  'MDLBSG_CACHE_OPT_IN_MENU_V89' \
  "$MENU_INSTALLED_TEXT" \
  || fail "installed native menu lost cache settings"

grep -Fq \
  'activateIgnoringOtherApps' \
  "$MENU_INSTALLED_TEXT" \
  || fail "installed native menu lost frontmost activation"

grep -Eq '^[[:space:]]*on run[[:space:]]*$' "$MENU_INSTALLED_TEXT" \
  || fail "installed native menu lost the parameterless run handler"

if grep -Eq '^[[:space:]]*on run[[:space:]]+argv[[:space:]]*$' "$MENU_INSTALLED_TEXT"; then
  fail "installed native menu still contains the broken on run argv handler"
fi

/usr/bin/codesign \
  --verify \
  --strict \
  "$HOME/.mdlbsg/MDLBSG Menu.app" \
  || fail "installed native menu signature verification failed"

VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$FINAL_APP/Contents/Info.plist"
)"

[[ "$VERSION" == "91" ]] \
  || fail "installed bundle version is $VERSION instead of 91"

/usr/bin/python3 - "$FINAL_APP/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])

with plist_path.open("rb") as handle:
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
        "APP 91 INSTALL FAILED: unused privacy keys remain: "
        + ", ".join(remaining)
    )

print("      unused privacy metadata: CLEAN")
PY

/usr/bin/codesign \
  --verify \
  --strict \
  "$FINAL_APP" \
  || fail "installed App 91 signature verification failed"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" \
    -f "$FINAL_APP" \
    >/dev/null 2>&1 || true
fi

killall Finder >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

cat > "$BIN/BUILD_INFO_APP91" <<EOF
built: $(date '+%Y-%m-%d %H:%M:%S')
app_version: App 91
queue_rule: later drops append to the active queue
worker_rule: exactly one queue worker and one progress window
processing_rule: queued items run sequentially in submission order
statistics_rule: one combined popup after the whole queue finishes
post_completion_rule: a new drop closes the previous statistics popup
launcher_rule: each open launches a native menu app whose applet run handler accepts the parameterless Finder run event
cache_rule: plaintext cache is off unless the user explicitly enables it
installed_app: $FINAL_APP
EOF

echo
echo "============================================================"
echo "APP 91 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo
echo "Installed behavior:"
echo "  - one active compression worker"
echo "  - later drops join the same live queue"
echo "  - one progress window"
echo "  - sequential processing"
echo "  - one combined statistics popup"
echo "  - opening the app launches a real frontmost menu application"
echo "  - plaintext cache is explicit opt-in from Cache Settings"
echo
