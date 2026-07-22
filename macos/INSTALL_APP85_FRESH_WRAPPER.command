#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

SOURCE="$HERE/MDLBSG_CompressorWindow.applescript"
BASE_INSTALLER="$HERE/INSTALL_MDLBSG.command"
HELPER_SOURCE="$HERE/src/mdlbsg_progress_window.m"
HELPER_BIN="$HOME/.mdlbsg/bin/mdlbsg_progress_window"

OSACOMPILE="/usr/bin/osacompile"
OSADECOMPILE="/usr/bin/osadecompile"

STAGE_ROOT=""

cleanup() {
  if [[ -n "${STAGE_ROOT:-}" && -d "$STAGE_ROOT" ]]; then
    rm -rf "$STAGE_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo
  echo "APP 85 INSTALL FAILED: $*" >&2
  echo "Nothing below this failure should be treated as installed proof." >&2
  exit 1
}

echo "============================================================"
echo "MDLBSG APP 85 — FRESH PROGRESS WRAPPER"
echo "============================================================"
echo

[[ -f "$SOURCE" ]] || fail "missing Compressor source"
[[ -f "$BASE_INSTALLER" ]] || fail "missing base installer"
[[ -f "$HELPER_SOURCE" ]] || fail "missing native progress helper source"

grep -Fq \
  "MDLBSG_FRESH_PROGRESS_WRAPPER_V85" \
  "$SOURCE" \
  || fail "App 85 source marker is missing"

grep -Fq \
  "mdlbsg_progress_window" \
  "$SOURCE" \
  || fail "custom progress helper routing is missing"

if grep -Eiq \
  'set[[:space:]]+progress[[:space:]]+(total|completed|description|additional)' \
  "$SOURCE"
then
  fail "built-in AppleScript progress commands remain in the source"
fi

if grep -Fq \
  "scheduleForcedFinishedProcessExit" \
  "$SOURCE"
then
  fail "old forced-process-exit logic remains in the source"
fi

echo "[1/7] Correcting stale process matching in the base installer..."

python3 - "$BASE_INSTALLER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace(
    "/Contents/MacOS/applet",
    "/Contents/MacOS/droplet",
)

path.write_text(text)

if "/Contents/MacOS/applet" in path.read_text():
    raise SystemExit(
        "Base installer still contains an incorrect applet path."
    )

print("Real droplet process matching: PASS")
PY

/bin/bash -n "$BASE_INSTALLER"

echo
echo "[2/7] Installing the unchanged compressor cores and handlers..."
echo

pkill -TERM -f \
  "$HOME/.mdlbsg/bin/mdlbsg_progress_window" \
  2>/dev/null || true

/bin/bash "$BASE_INSTALLER"

echo
echo "[3/7] Compiling the fresh native progress helper..."

mkdir -p "$HOME/.mdlbsg/bin"

/usr/bin/clang \
  -fobjc-arc \
  -O2 \
  -Wall \
  -Wextra \
  -framework Cocoa \
  "$HELPER_SOURCE" \
  -o "$HELPER_BIN" \
  || fail "native progress helper did not compile"

chmod +x "$HELPER_BIN"

SELF_TEST="$("$HELPER_BIN" --self-test)" \
  || fail "native progress helper self-test failed"

[[ "$SELF_TEST" == *"MDLBSG_PROGRESS_WINDOW_SELF_TEST_PASS"* ]] \
  || fail "native helper self-test returned unexpected output"

echo "      native helper compile: PASS"
echo "      native helper executable self-test: PASS"

echo
echo "[4/7] Testing the real open → close progress lifecycle..."

LIFE_ROOT="$(
  mktemp -d "${TMPDIR:-/tmp}/mdlbsg-progress-life.XXXXXX"
)"

LIFE_STATE="$LIFE_ROOT/state"
LIFE_CANCEL="$LIFE_ROOT/cancel"
LIFE_CLOSED="$LIFE_ROOT/closed"
LIFE_READY="$LIFE_ROOT/ready"

/usr/bin/printf '%s\n%s\n%s\n' \
  "25" \
  "MDLBSG App 85 wrapper test" \
  "Testing controlled window closure..." \
  > "$LIFE_STATE"

"$HELPER_BIN" \
  --state "$LIFE_STATE" \
  --cancel "$LIFE_CANCEL" \
  --closed "$LIFE_CLOSED" \
  --ready "$LIFE_READY" \
  >/dev/null 2>&1 &

LIFE_PID="$!"

READY_PASS=NO

for _ in $(seq 1 80); do
  if [[ -f "$LIFE_READY" ]]; then
    READY_PASS=YES
    break
  fi

  sleep 0.05
done

[[ "$READY_PASS" == "YES" ]] \
  || fail "native progress window never became ready"

/usr/bin/printf 'CLOSE\n' > "$LIFE_STATE"

CLOSED_PASS=NO

for _ in $(seq 1 80); do
  if [[ -f "$LIFE_CLOSED" ]]; then
    CLOSED_PASS=YES
    break
  fi

  sleep 0.05
done

[[ "$CLOSED_PASS" == "YES" ]] \
  || fail "native progress window did not acknowledge closure"

wait "$LIFE_PID" \
  || fail "native progress helper did not exit cleanly"

rm -rf "$LIFE_ROOT"

echo "      progress window became ready: PASS"
echo "      CLOSE condition closed window: PASS"
echo "      progress process exited: PASS"

echo
echo "[5/7] Performing source-only App 85 compile proof..."

STAGE_ROOT="$(
  mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app85-stage.XXXXXX"
)"

TEST_APP="$STAGE_ROOT/Source Test.app"
TEST_MAIN="$TEST_APP/Contents/Resources/Scripts/main.scpt"
TEST_TEXT="$STAGE_ROOT/source-test.applescript"

"$OSACOMPILE" \
  -o "$TEST_APP" \
  "$SOURCE" \
  || fail "App 85 AppleScript source did not compile"

[[ -f "$TEST_MAIN" ]] \
  || fail "source test produced no main.scpt"

"$OSADECOMPILE" \
  "$TEST_MAIN" \
  > "$TEST_TEXT" \
  || fail "source test could not be decompiled"

grep -Fq \
  "MDLBSG_FRESH_PROGRESS_WRAPPER_V85" \
  "$TEST_TEXT" \
  || fail "compiled source lost the App 85 marker"

grep -Fq \
  "mdlbsg_progress_window" \
  "$TEST_TEXT" \
  || fail "compiled source lost custom helper routing"

grep -Fiq \
  "on closefreshprogresswindow" \
  "$TEST_TEXT" \
  || fail "compiled source lost the controlled close handler"

if grep -Eiq \
  'set[[:space:]]+progress[[:space:]]+(total|completed|description|additional)' \
  "$TEST_TEXT"
then
  fail "compiled source still contains built-in progress commands"
fi

if grep -Fq \
  "scheduleForcedFinishedProcessExit" \
  "$TEST_TEXT"
then
  fail "compiled source still contains old forced-exit logic"
fi

echo "      App 85 osacompile: PASS"
echo "      App 85 marker: PASS"
echo "      controlled close handler: PASS"
echo "      built-in progress commands: ZERO"
echo "      old forced-exit logic: ABSENT"

echo
echo "[6/7] Building and installing the final App 85 bundle..."

FINAL_STAGE="$STAGE_ROOT/MDLBSG Compressor.app"

"$OSACOMPILE" \
  -o "$FINAL_STAGE" \
  "$SOURCE" \
  || fail "final App 85 bundle did not compile"

if command -v iconutil >/dev/null 2>&1 &&
   [[ -d "$HERE/icons/Compressor.iconset" ]]
then
  ICON_FILE="$STAGE_ROOT/Compressor.icns"

  iconutil \
    -c icns \
    "$HERE/icons/Compressor.iconset" \
    -o "$ICON_FILE" \
    2>/dev/null || true

  EXISTING_ICON="$(
    find "$FINAL_STAGE/Contents/Resources" \
      -maxdepth 1 \
      -name '*.icns' \
      -print \
      -quit \
      2>/dev/null || true
  )"

  if [[ -f "$ICON_FILE" && -n "$EXISTING_ICON" ]]; then
    cp "$ICON_FILE" "$EXISTING_ICON"
  fi
fi

python3 \
  "$HERE/configure_app.py" \
  "$FINAL_STAGE" \
  "com.mdlbsg.compressor" \
  "MDLBSG Compressor" \
  --bundle-version 85 \
  || fail "could not configure the App 85 bundle identity"

xattr -cr "$FINAL_STAGE" 2>/dev/null || true

find "$FINAL_STAGE" \
  -name $'Icon\r' \
  -delete \
  2>/dev/null || true

chmod a-w \
  "$FINAL_STAGE/Contents/Resources/Scripts/main.scpt" \
  2>/dev/null || true

/usr/bin/codesign \
  --force \
  --sign - \
  "$FINAL_STAGE" \
  || fail "App 85 codesign failed"

/usr/bin/codesign \
  --verify \
  --strict \
  "$FINAL_STAGE" \
  || fail "staged App 85 signature verification failed"

FINAL_TEXT="$STAGE_ROOT/final-stage.applescript"

"$OSADECOMPILE" \
  "$FINAL_STAGE/Contents/Resources/Scripts/main.scpt" \
  > "$FINAL_TEXT" \
  || fail "final staged App 85 could not be decompiled"

grep -Fq \
  "MDLBSG_FRESH_PROGRESS_WRAPPER_V85" \
  "$FINAL_TEXT" \
  || fail "final staged app lost the App 85 marker"

grep -Fq \
  "mdlbsg_progress_window" \
  "$FINAL_TEXT" \
  || fail "final staged app lost custom progress routing"

if grep -Eiq \
  'set[[:space:]]+progress[[:space:]]+(total|completed|description|additional)' \
  "$FINAL_TEXT"
then
  fail "final staged app contains built-in AppleScript progress"
fi

for executable in droplet applet
do
  pkill -TERM -f \
    "/MDLBSG Compressor.app/Contents/MacOS/${executable}" \
    2>/dev/null || true
done

pkill -TERM -f \
  "$HOME/.mdlbsg/bin/mdlbsg_progress_window" \
  2>/dev/null || true

sleep 2

for executable in droplet applet
do
  pattern="/MDLBSG Compressor.app/Contents/MacOS/${executable}"

  if pgrep -f "$pattern" >/dev/null 2>&1; then
    pkill -KILL -f "$pattern" 2>/dev/null || true
  fi
done

pkill -KILL -f \
  "$HOME/.mdlbsg/bin/mdlbsg_progress_window" \
  2>/dev/null || true

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
BACKUP="$HOME/Downloads/MDLBSG_Compressor_before_App85_$(date '+%Y%m%d_%H%M%S').app"

if [[ -d "$FINAL_APP" ]]; then
  cp -R "$FINAL_APP" "$BACKUP"

  echo "      previous Compressor backed up to:"
  echo "      $BACKUP"
fi

rm -rf "$FINAL_APP"
mv "$FINAL_STAGE" "$FINAL_APP"

INSTALLED_MAIN="$FINAL_APP/Contents/Resources/Scripts/main.scpt"
INSTALLED_TEXT="$STAGE_ROOT/installed-app85.applescript"

[[ -f "$INSTALLED_MAIN" ]] \
  || fail "installed App 85 main.scpt is missing"

"$OSADECOMPILE" \
  "$INSTALLED_MAIN" \
  > "$INSTALLED_TEXT" \
  || fail "installed App 85 could not be decompiled"

grep -Fq \
  "MDLBSG_FRESH_PROGRESS_WRAPPER_V85" \
  "$INSTALLED_TEXT" \
  || fail "installed app lost the App 85 marker"

grep -Fq \
  "mdlbsg_progress_window" \
  "$INSTALLED_TEXT" \
  || fail "installed app lost custom progress routing"

if grep -Eiq \
  'set[[:space:]]+progress[[:space:]]+(total|completed|description|additional)' \
  "$INSTALLED_TEXT"
then
  fail "installed app contains built-in AppleScript progress"
fi

if grep -Fq \
  "scheduleForcedFinishedProcessExit" \
  "$INSTALLED_TEXT"
then
  fail "installed app contains old forced-exit logic"
fi

/usr/bin/codesign \
  --verify \
  --strict \
  "$FINAL_APP" \
  || fail "installed App 85 signature is invalid"

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

[[ "$VERSION" == "85" ]] \
  || fail "installed bundle version is not 85"

echo "      installed app: $FINAL_APP"
echo "      installed executable: droplet"
echo "      installed bundle version: 85"
echo "      fresh progress helper routing: YES"
echo "      built-in progress commands: ZERO"
echo "      forced PID termination logic: ZERO"
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

cat > "$HOME/.mdlbsg/bin/BUILD_INFO_APP85" <<EOF
built: $(date '+%Y-%m-%d %H:%M:%S')
app_version: App 85
architecture: fresh conditional progress wrapper
compressor_core: unchanged
compressor_handler: ~/.mdlbsg/bin/mdlbsg_droplet_handler.sh
progress_owner: mdlbsg_progress_window
completion_condition: handler process exited and result file exists
completion_order: progress closes before statistics launch
builtin_applescript_progress_commands: zero
forced_process_kill_completion_logic: zero
installed_app: $FINAL_APP
EOF

echo
echo "============================================================"
echo "APP 85 INSTALLED SUCCESSFULLY"
echo "============================================================"
echo
echo "The workflow is unchanged:"
echo "  1. Drag a file onto MDLBSG Compressor."
echo "  2. The fresh progress window opens."
echo "  3. The existing compressor runs."
echo "  4. Actual compressor completion triggers CLOSE."
echo "  5. The progress window closes itself."
echo "  6. Only then does the statistics popup open."
echo
