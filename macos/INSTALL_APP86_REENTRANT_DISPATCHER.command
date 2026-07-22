#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

SOURCE="$HERE/MDLBSG_CompressorWindow.applescript"
WORKER_SOURCE="$HERE/src/mdlbsg_ui_worker.py"
APP85_INSTALLER="$HERE/INSTALL_APP85_FRESH_WRAPPER.command"
CONFIGURE_APP="$HERE/configure_app.py"

BIN="$HOME/.mdlbsg/bin"
WORKER_INSTALLED="$BIN/mdlbsg_ui_worker.py"

STAGE_ROOT=""

cleanup() {
  if [[ -n "${STAGE_ROOT:-}" && -d "$STAGE_ROOT" ]]; then
    rm -rf "$STAGE_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo
  echo "APP 86 INSTALL FAILED: $*" >&2
  echo "Nothing below this failure is installed proof." >&2
  exit 1
}

echo "============================================================"
echo "MDLBSG APP 86 — REENTRANT JOB DISPATCHER"
echo "============================================================"
echo

[[ -f "$SOURCE" ]] || fail "missing App 86 source"
[[ -f "$WORKER_SOURCE" ]] || fail "missing App 86 worker"
[[ -f "$CONFIGURE_APP" ]] || fail "missing configure_app.py"

grep -Fq \
  "MDLBSG_REENTRANT_DISPATCHER_V86" \
  "$SOURCE" \
  || fail "App 86 source marker is missing"

grep -Fq \
  "closePreviousResultsPopup" \
  "$SOURCE" \
  || fail "old-results close behavior is missing"

grep -Fq \
  "mdlbsg_ui_worker.py" \
  "$SOURCE" \
  || fail "worker dispatch is missing"

REQUIRED_COMPONENTS=(
  "$BIN/mdlbsg_droplet_handler.sh"
  "$BIN/mdlbsg_detached_spawn"
  "$BIN/mdlbsg_progress_window"
  "$HOME/.mdlbsg/results_dialog.applescript"
)

MISSING=NO

for component in "${REQUIRED_COMPONENTS[@]}"; do
  if [[ ! -e "$component" ]]; then
    MISSING=YES
  fi
done

if [[ "$MISSING" == "YES" ]]; then
  echo "[1/7] App 85 prerequisites are missing; installing them..."
  echo

  [[ -f "$APP85_INSTALLER" ]] \
    || fail "App 85 prerequisite installer is unavailable"

  chmod +x "$APP85_INSTALLER"

  /bin/bash "$APP85_INSTALLER"
else
  echo "[1/7] Existing compressor core and App 85 UI prerequisites: FOUND"
fi

for component in "${REQUIRED_COMPONENTS[@]}"; do
  [[ -e "$component" ]] \
    || fail "required component is still missing: $component"
done

echo
echo "[2/7] Installing and testing the independent App 86 worker..."

mkdir -p "$BIN"

cp "$WORKER_SOURCE" "$WORKER_INSTALLED"
chmod +x "$WORKER_INSTALLED"

WORKER_TEST="$(
  /usr/bin/python3 \
    "$WORKER_INSTALLED" \
    --self-test
)"

[[ "$WORKER_TEST" == *"MDLBSG_APP86_WORKER_SELF_TEST_PASS"* ]] \
  || fail "App 86 worker self-test failed"

echo "      worker executable: PASS"
echo "      worker self-test: PASS"

echo
echo "[3/7] Performing source-only AppleScript compile proof..."

STAGE_ROOT="$(
  mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app86-stage.XXXXXX"
)"

TEST_APP="$STAGE_ROOT/App86 Source Test.app"
TEST_MAIN="$TEST_APP/Contents/Resources/Scripts/main.scpt"
TEST_TEXT="$STAGE_ROOT/app86-source-test.applescript"

/usr/bin/osacompile \
  -o "$TEST_APP" \
  "$SOURCE" \
  || fail "App 86 AppleScript source did not compile"

[[ -f "$TEST_MAIN" ]] \
  || fail "source test produced no main.scpt"

/usr/bin/osadecompile \
  "$TEST_MAIN" \
  > "$TEST_TEXT" \
  || fail "source test could not be decompiled"

grep -Fq \
  "MDLBSG_REENTRANT_DISPATCHER_V86" \
  "$TEST_TEXT" \
  || fail "compiled source lost the App 86 marker"

grep -Fq \
  "mdlbsg_ui_worker.py" \
  "$TEST_TEXT" \
  || fail "compiled source lost the worker path"

grep -Fiq \
  "closepreviousresultspopup" \
  "$TEST_TEXT" \
  || fail "compiled source lost old-results closure"

grep -Fiq \
  "dispatchfreshworker" \
  "$TEST_TEXT" \
  || fail "compiled source lost worker dispatch"

echo "      AppleScript compile: PASS"
echo "      worker dispatch: PASS"
echo "      old-stats closure: PASS"

echo
echo "[4/7] Building the App 86 Compressor bundle..."

FINAL_STAGE="$STAGE_ROOT/MDLBSG Compressor.app"

/usr/bin/osacompile \
  -o "$FINAL_STAGE" \
  "$SOURCE" \
  || fail "final App 86 bundle did not compile"

python3 \
  "$CONFIGURE_APP" \
  "$FINAL_STAGE" \
  "com.mdlbsg.compressor" \
  "MDLBSG Compressor" \
  --bundle-version 86 \
  || fail "could not configure App 86 identity"

EXISTING_APP=""

if [[ -d "/Applications/MDLBSG Compressor.app" ]]; then
  EXISTING_APP="/Applications/MDLBSG Compressor.app"
elif [[ -d "$HOME/Applications/MDLBSG Compressor.app" ]]; then
  EXISTING_APP="$HOME/Applications/MDLBSG Compressor.app"
fi

if [[ -n "$EXISTING_APP" ]]; then
  OLD_ICON="$(
    find "$EXISTING_APP/Contents/Resources" \
      -maxdepth 1 \
      -type f \
      -name '*.icns' \
      -print \
      -quit \
      2>/dev/null || true
  )"

  NEW_ICON="$(
    find "$FINAL_STAGE/Contents/Resources" \
      -maxdepth 1 \
      -type f \
      -name '*.icns' \
      -print \
      -quit \
      2>/dev/null || true
  )"

  if [[ -n "$OLD_ICON" && -n "$NEW_ICON" ]]; then
    cp "$OLD_ICON" "$NEW_ICON"
  fi
fi

xattr -cr "$FINAL_STAGE" 2>/dev/null || true

find "$FINAL_STAGE" \
  -name $'Icon\r' \
  -delete \
  2>/dev/null || true

/usr/bin/codesign \
  --force \
  --sign - \
  "$FINAL_STAGE" \
  || fail "App 86 codesign failed"

/usr/bin/codesign \
  --verify \
  --strict \
  "$FINAL_STAGE" \
  || fail "staged App 86 signature verification failed"

echo "      final App 86 bundle compile: PASS"
echo "      final App 86 signature: PASS"

echo
echo "[5/7] Closing the old statistics popup and stopping the old app..."

RESULT_PATTERN='^/usr/bin/osascript .*[/]results_dialog[.]applescript'

pkill -TERM -f "$RESULT_PATTERN" 2>/dev/null || true

pkill -TERM -f \
  '^/usr/bin/osascript .*[/]launcher_dialog[.]applescript' \
  2>/dev/null || true

for executable in droplet applet; do
  pkill -TERM -f \
    "/MDLBSG Compressor.app/Contents/MacOS/${executable}" \
    2>/dev/null || true
done

sleep 2

for executable in droplet applet; do
  pattern="/MDLBSG Compressor.app/Contents/MacOS/${executable}"

  if pgrep -f "$pattern" >/dev/null 2>&1; then
    pkill -KILL -f "$pattern" 2>/dev/null || true
  fi
done

sleep 1

for executable in droplet applet; do
  pattern="/MDLBSG Compressor.app/Contents/MacOS/${executable}"

  if pgrep -f "$pattern" >/dev/null 2>&1; then
    fail "old Compressor process survived: $pattern"
  fi
done

echo "      old statistics popup: CLOSED"
echo "      old Compressor process: STOPPED"

echo
echo "[6/7] Installing and proving App 86..."

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
  BACKUP="$HOME/Downloads/MDLBSG_Compressor_before_App86_$(date '+%Y%m%d_%H%M%S').app"

  cp -R "$FINAL_APP" "$BACKUP"

  echo "      previous app backup:"
  echo "      $BACKUP"
fi

rm -rf "$FINAL_APP"
mv "$FINAL_STAGE" "$FINAL_APP"

INSTALLED_MAIN="$FINAL_APP/Contents/Resources/Scripts/main.scpt"
INSTALLED_TEXT="$STAGE_ROOT/installed-app86.applescript"

[[ -f "$INSTALLED_MAIN" ]] \
  || fail "installed App 86 main.scpt is missing"

/usr/bin/osadecompile \
  "$INSTALLED_MAIN" \
  > "$INSTALLED_TEXT" \
  || fail "installed App 86 could not be decompiled"

grep -Fq \
  "MDLBSG_REENTRANT_DISPATCHER_V86" \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the App 86 marker"

grep -Fq \
  "mdlbsg_ui_worker.py" \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the worker dispatch"

grep -Fiq \
  "closepreviousresultspopup" \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the old-stats close rule"

/usr/bin/codesign \
  --verify \
  --strict \
  "$FINAL_APP" \
  || fail "installed App 86 signature is invalid"

EXECUTABLE="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$FINAL_APP/Contents/Info.plist" \
    2>/dev/null || true
)"

VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$FINAL_APP/Contents/Info.plist" \
    2>/dev/null || true
)"

[[ "$EXECUTABLE" == "droplet" ]] \
  || fail "installed executable is not droplet"

[[ "$VERSION" == "86" ]] \
  || fail "installed bundle version is not 86"

echo "      installed executable: droplet"
echo "      installed bundle version: 86"
echo "      worker dispatch present: YES"
echo "      old-stats close rule present: YES"
echo "      installed signature: PASS"

echo
echo "[7/7] Refreshing Finder and Launch Services..."

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" \
    -f "$FINAL_APP" \
    >/dev/null 2>&1 || true
fi

killall Finder >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

cat > "$BIN/BUILD_INFO_APP86" <<EOF
built: $(date '+%Y-%m-%d %H:%M:%S')
app_version: App 86
architecture: lightweight droplet plus detached worker
compressor_core: unchanged
new_drop_rule: close previous completed statistics popup
progress_owner: mdlbsg_progress_window
worker: $WORKER_INSTALLED
completion_order: compressor ends -> progress closes -> statistics opens
dispatcher_exit: immediately after detached worker launch
installed_app: $FINAL_APP
EOF

echo
echo "============================================================"
echo "APP 86 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo
echo "New exact behavior:"
echo "  1. Drag a file onto MDLBSG Compressor."
echo "  2. The app launches an independent worker and exits."
echo "  3. Progress opens and compression runs."
echo "  4. Progress closes before statistics opens."
echo "  5. Leave the statistics popup open."
echo "  6. Drag another file onto the app."
echo "  7. The old statistics popup closes immediately."
echo "  8. A fresh progress window starts."
echo
