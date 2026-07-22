#!/usr/bin/env bash
# MDLBSG App 82 — build the applets in a clean staging directory, prove their
# compiled contents, then replace the installed bundles. No success stamp is
# written until the exact installed main.scpt is verified.
set -euo pipefail

APP_VERSION="App 82 (TRUE-DETACH RC1)"
PACKAGE_MARKER="MDLBSG_APP_82_TRUE_DETACH_2026_07_21"
SOURCE_MARKER="MDLBSG_RESULTS_DIALOG_V80_INSTALL_PROOF"
TRANSIENT_UI_MARKER="MDLBSG_TRANSIENT_UI_V81"
TRUE_DETACH_MARKER="MDLBSG_TRUE_DETACH_V82"
DETACH_NEEDLE="mdlbsg_detached_spawn"
MENU_NEEDLE="launcher_dialog.applescript"
RESULTS_NEEDLE="results_dialog.applescript"
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MDLBSG_CompressorWindow.applescript"
DECOMP_SOURCE="$HERE/MDLBSG_DecompressorWindow.applescript"
OSACOMPILE="${OSACOMPILE:-/usr/bin/osacompile}"
OSADECOMPILE="${OSADECOMPILE:-/usr/bin/osadecompile}"
STAGE_ROOT=""

fail() {
  echo
  echo "INSTALL FAILED: $*" >&2
  echo "Nothing below this failure should be treated as installed proof." >&2
  exit 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

cleanup() {
  if [ -n "${STAGE_ROOT:-}" ] && [ -d "$STAGE_ROOT" ]; then
    rm -rf "$STAGE_ROOT"
  fi
}
trap cleanup EXIT

echo "== mdlbsg verified installer =="
echo "      app version:      $APP_VERSION"
echo "      package marker:   $PACKAGE_MARKER"
echo "      installer path:   $HERE/INSTALL_MDLBSG.command"
echo "      compressor source:$SOURCE"

[ -f "$SOURCE" ] || fail "missing compressor source: $SOURCE"
[ -f "$DECOMP_SOURCE" ] || fail "missing decompressor source: $DECOMP_SOURCE"
[ -x "$OSACOMPILE" ] || fail "osacompile not found at $OSACOMPILE"
[ -x "$OSADECOMPILE" ] || fail "osadecompile not found at $OSADECOMPILE"
grep -Fq "$PACKAGE_MARKER" "$HERE/INSTALL_MDLBSG.command" \
  || fail "this is not the App 82 installer"
grep -Fq "$SOURCE_MARKER" "$SOURCE" \
  || fail "stale compressor source: compiled-source marker is missing"
grep -Fq "$RESULTS_NEEDLE" "$SOURCE" \
  || fail "stale compressor source: results-dialog code is missing"
grep -Fq "$TRANSIENT_UI_MARKER" "$SOURCE" \
  || fail "stale compressor source: App 81 transient-UI marker is missing"
grep -Fq "$TRUE_DETACH_MARKER" "$SOURCE" \
  || fail "stale compressor source: App 82 true-detach marker is missing"
grep -Fq "$DETACH_NEEDLE" "$SOURCE" \
  || fail "stale compressor source: native detached-launcher path is missing"
grep -Fq "$MENU_NEEDLE" "$SOURCE" \
  || fail "stale compressor source: detached menu-helper path is missing"
SOURCE_SHA="$(sha256_file "$SOURCE")"
echo "      source freshness: EXACT App 82 source verified"
echo "      source sha256:    $SOURCE_SHA"

mkdir -p "$HOME/.mdlbsg/bin"

echo "[1/6] stopping only running MDLBSG app/core processes..."
/usr/bin/pkill -f '^/usr/bin/osascript .*[/]launcher_dialog[.]applescript' 2>/dev/null || true
# Do not use broad 'pkill -f MDLBSG': the installer path itself contains MDLBSG.
for pattern in \
  '/MDLBSG Compressor.app/Contents/MacOS/droplet' \
  '/MDLBSG Decompressor.app/Contents/MacOS/droplet' \
  "$HOME/.mdlbsg/bin/mdlbsg_core" \
  "$HOME/.mdlbsg/bin/mdlbsg_turbo" \
  "$HOME/.mdlbsg/bin/mdlbsg_turbo_v1"
do
  pkill -f "$pattern" 2>/dev/null || true
done
sleep 1
for pattern in \
  '/MDLBSG Compressor.app/Contents/MacOS/droplet' \
  '/MDLBSG Decompressor.app/Contents/MacOS/droplet'
do
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    fail "an old MDLBSG app process is still running: $pattern"
  fi
done
echo "      old app processes: stopped"

echo "[2/6] compiling cores (30-90s)..."
clang++ -O3 -march=native -std=c++17 -o "$HOME/.mdlbsg/bin/mdlbsg_core" "$HERE/src/mdlbsg_app.cpp" 2>/dev/null \
  || clang++ -O3 -std=c++17 -o "$HOME/.mdlbsg/bin/mdlbsg_core" "$HERE/src/mdlbsg_app.cpp"
clang++ -O3 -march=native -std=c++17 -o "$HOME/.mdlbsg/bin/mdlbsg_turbo" "$HERE/src/mdlbsg_turbo_app.cpp" 2>/dev/null \
  || clang++ -O3 -std=c++17 -o "$HOME/.mdlbsg/bin/mdlbsg_turbo" "$HERE/src/mdlbsg_turbo_app.cpp"
clang++ -O3 -march=native -std=c++17 -pthread -o "$HOME/.mdlbsg/bin/mdlbsg_turbo_v1" "$HERE/src/mdlbsg_turbo_v1.cpp" 2>/dev/null \
  || clang++ -O3 -std=c++17 -pthread -o "$HOME/.mdlbsg/bin/mdlbsg_turbo_v1" "$HERE/src/mdlbsg_turbo_v1.cpp"
clang -O2 -Wall -Wextra -o "$HOME/.mdlbsg/bin/mdlbsg_detached_spawn" "$HERE/src/mdlbsg_detached_spawn.c" \
  || fail "could not compile native detached-results launcher"
chmod +x "$HOME/.mdlbsg/bin/mdlbsg_detached_spawn"
[ -x "$HOME/.mdlbsg/bin/mdlbsg_detached_spawn" ] \
  || fail "native detached-results launcher is not executable"
DETACH_TEST_DONE="${TMPDIR:-/tmp}/mdlbsg-detach-test.$$"
rm -f "$DETACH_TEST_DONE"
"$HOME/.mdlbsg/bin/mdlbsg_detached_spawn" /bin/sh -c "sleep 1; : > '$DETACH_TEST_DONE'" \
  || fail "native detached-results launcher could not start a child"
[ ! -e "$DETACH_TEST_DONE" ] \
  || fail "native detached-results launcher waited for its child instead of detaching"
DETACH_TEST_PASS=NO
for _ in $(seq 1 40); do
  if [ -e "$DETACH_TEST_DONE" ]; then
    DETACH_TEST_PASS=YES
    break
  fi
  sleep 0.1
done
rm -f "$DETACH_TEST_DONE"
[ "$DETACH_TEST_PASS" = YES ] \
  || fail "native detached-results launcher returned, but its child never executed"
echo "      native detached launcher self-test: PASS"
echo "      cores and native detached launcher built."

echo "[3/6] installing command, handlers, and detached UI helpers..."
cp "$HERE/mdlbsg" "$HOME/.mdlbsg/bin/mdlbsg"; chmod +x "$HOME/.mdlbsg/bin/mdlbsg"
cp "$HERE/mdlbsg_droplet_handler.sh" "$HOME/.mdlbsg/bin/mdlbsg_droplet_handler.sh"; chmod +x "$HOME/.mdlbsg/bin/mdlbsg_droplet_handler.sh"
cp "$HERE/mdlbsg_extract_handler.sh" "$HOME/.mdlbsg/bin/mdlbsg_extract_handler.sh"; chmod +x "$HOME/.mdlbsg/bin/mdlbsg_extract_handler.sh"
cp "$HERE/dock_install.py" "$HOME/.mdlbsg/bin/dock_install.py"

cat > "$HOME/.mdlbsg/results_dialog.applescript" << 'DLGEOF'
on run argv
	set p to item 1 of argv
	try
		do shell script "mkdir -p ~/.mdlbsg && echo \"$(date '+%Y-%m-%d %H:%M:%S') results-helper-start " & quoted form of p & "\" >> ~/.mdlbsg/launch.log"
	end try
	set t to ""
	try
		set t to read POSIX file p as «class utf8»
	end try
	try
		do shell script "rm -f " & quoted form of p
	end try
	if t is "" then return
	activate
	set dlg to display dialog t with title "MDLBSG Compressor" buttons {"Save Folder...", "OK"} default button "OK" with icon note
	try
		do shell script "echo \"$(date '+%Y-%m-%d %H:%M:%S') results-helper-dialog-returned\" >> ~/.mdlbsg/launch.log"
	end try
	if button returned of dlg is "Save Folder..." then
		try
			set f to POSIX path of (choose folder with prompt "Where should MDLBSG save its output?")
			set d2 to display dialog "Save to this folder every time?" & return & return & f with title "Save Location" buttons {"Just This Once", "Always Save Here"} default button "Always Save Here" with icon note
			if button returned of d2 is "Always Save Here" then
				do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of f & " > ~/.mdlbsg/destdir"
			else
				do shell script "rm -f ~/.mdlbsg/destdir"
			end if
		end try
	end if
end run
DLGEOF
chmod 644 "$HOME/.mdlbsg/results_dialog.applescript"

cat > "$HOME/.mdlbsg/launcher_dialog.applescript" << 'MENUEOF'
-- MDLBSG_LAUNCHER_DIALOG_V81
use AppleScript version "2.4"
use scripting additions
use framework "AppKit"

property compressorBundleID : "com.mdlbsg.compressor"

on currentMode()
	try
		set m to do shell script "cat ~/.mdlbsg/preset 2>/dev/null | tr -d '[:space:]'"
		if m is "fast" or m is "turbo" or m is "max" then return m
	end try
	return "turbo"
end currentMode

on modeDetail(m)
	if m is "fast" then return "Fastest - Fastest Speed, Least Compression"
	if m is "turbo" then return "Turbo V1 - Best Speed/Compression Ratio"
	return "Max Mode - Best Compression, Slowest Speed"
end modeDetail

on changeMode()
	set cur to my currentMode()
	set opts to {"Fastest - Fastest Speed, Least Compression", "Turbo V1 - Best Speed/Compression Ratio", "Max Mode - Best Compression, Slowest Speed"}
	set def to item 2 of opts
	if cur is "fast" then set def to item 1 of opts
	if cur is "max" then set def to item 3 of opts
	activate
	set chosen to (choose from list opts with prompt "Compression mode:" default items {def} with title "MDLBSG Compressor" OK button name "Use This Mode")
	if chosen is false then return
	set c to item 1 of chosen
	if c starts with "Fastest" then
		set m to "fast"
	else if c starts with "Turbo" then
		set m to "turbo"
	else
		set m to "max"
	end if
	do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of m & " > ~/.mdlbsg/preset"
end changeMode

on mainMenu(modeLine)
	try
		activate
		set alert to current application's NSAlert's alloc()'s init()
		alert's setMessageText:"MDLBSG Compressor"
		alert's setInformativeText:(modeLine & return & return & "Files and folders are compressed to a .mdl archive and saved to your chosen folder. Folders are compressed as a single unit." & return & return & "You can also drag files or folders onto the app's icon.")
		alert's setAlertStyle:1
		alert's addButtonWithTitle:"Choose Files"
		alert's addButtonWithTitle:"Choose Folder"
		alert's addButtonWithTitle:"Change Mode"
		alert's addButtonWithTitle:"Quit"
		set answer to (alert's runModal()) as integer
		if answer is 1000 then return "files"
		if answer is 1001 then return "folder"
		if answer is 1002 then return "mode"
		return "quit"
	on error
		return "quit"
	end try
end mainMenu

on sendPaths(thePaths)
	if (count of thePaths) is 0 then return
	set cmd to "/usr/bin/open -b " & quoted form of compressorBundleID
	repeat with p in thePaths
		set cmd to cmd & " " & quoted form of (p as text)
	end repeat
	do shell script cmd
end sendPaths

on run
	-- A short grace period lets an initial drag deliver its open event first.
	-- The Compressor's open handler kills this helper before any menu appears.
	delay 0.7
	repeat
		set m to my currentMode()
		set act to my mainMenu("MDLBSG is currently set to: " & my modeDetail(m))
		if act is "quit" then return
		if act is "mode" then
			my changeMode()
		else if act is "files" then
			try
				set picked to choose file with prompt "Choose files to compress:" default location (path to downloads folder) with multiple selections allowed
				set pathsOut to {}
				repeat with pf in picked
					set end of pathsOut to POSIX path of pf
				end repeat
				my sendPaths(pathsOut)
				return
			on error number -128
			end try
		else if act is "folder" then
			try
				set f to POSIX path of (choose folder with prompt "Choose a folder to compress:" default location (path to downloads folder))
				my sendPaths({f})
				return
			on error number -128
			end try
		end if
	end repeat
end run
MENUEOF
chmod 644 "$HOME/.mdlbsg/launcher_dialog.applescript"
grep -Fq "MDLBSG_LAUNCHER_DIALOG_V81" "$HOME/.mdlbsg/launcher_dialog.applescript" \
  || fail "launcher dialog helper was not installed correctly"


rm -rf "/Applications/MDLBSG Results.app" "$HOME/Applications/MDLBSG Results.app" 2>/dev/null || true
rm -f "$HOME/.mdlbsg/results_app_path" 2>/dev/null || true
rm -rf "$HOME/.mdlbsg/results_spool" 2>/dev/null || true

if [ -w /usr/local/bin ] 2>/dev/null; then
  ln -sf "$HOME/.mdlbsg/bin/mdlbsg" /usr/local/bin/mdlbsg
  echo "      command installed to /usr/local/bin/mdlbsg"
else
  SHELLRC="$HOME/.zshrc"
  grep -q '.mdlbsg/bin' "$SHELLRC" 2>/dev/null || echo 'export PATH="$HOME/.mdlbsg/bin:$PATH"' >> "$SHELLRC"
  echo "      command installed to ~/.mdlbsg/bin"
fi

if [ -w /Applications ]; then
  APPDIR="/Applications"
else
  APPDIR="$HOME/Applications"
  mkdir -p "$APPDIR"
fi
COMPRESSOR_APP="$APPDIR/MDLBSG Compressor.app"
DECOMPRESSOR_APP="$APPDIR/MDLBSG Decompressor.app"

STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mdlbsg-app82.XXXXXX")"
STAGE_COMPRESSOR="$STAGE_ROOT/MDLBSG Compressor.app"
STAGE_DECOMPRESSOR="$STAGE_ROOT/MDLBSG Decompressor.app"

echo "[4/6] compiling into a clean staging directory..."
"$OSACOMPILE" -o "$STAGE_COMPRESSOR" "$SOURCE" \
  || fail "osacompile failed for the Compressor"
"$OSACOMPILE" -o "$STAGE_DECOMPRESSOR" "$DECOMP_SOURCE" \
  || fail "osacompile failed for the Decompressor"

STAGE_MAIN="$STAGE_COMPRESSOR/Contents/Resources/Scripts/main.scpt"
[ -f "$STAGE_MAIN" ] || fail "osacompile produced no Compressor main.scpt"
STAGE_DECOMPILED="$STAGE_ROOT/staged_compressor.decompiled.applescript"
"$OSADECOMPILE" "$STAGE_MAIN" > "$STAGE_DECOMPILED" \
  || fail "osadecompile failed for staged Compressor main.scpt"
grep -Fq "$SOURCE_MARKER" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing the exact source proof property"
grep -Fiq "on showresults" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing the showResults handler"
grep -Fq "$TRANSIENT_UI_MARKER" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing the App 81 transient-UI proof property"
grep -Fq "$TRUE_DETACH_MARKER" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing the App 82 true-detach proof property"
grep -Fq "$DETACH_NEEDLE" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing the native detached-launcher call"
grep -Fiq "quit" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing transient-app quit"
grep -Fiq "on launchmenuhelper" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing launchMenuHelper"
grep -Fq "$MENU_NEEDLE" "$STAGE_DECOMPILED" \
  || fail "staged compiled app is missing the detached menu-helper path"
STAGE_RESULTS_COUNT="$(grep -Fc "$RESULTS_NEEDLE" "$STAGE_DECOMPILED" || true)"
[ "$STAGE_RESULTS_COUNT" -ge 1 ] \
  || fail "staged compiled app is missing the detached results-dialog path"
STAGE_MAIN_SHA="$(sha256_file "$STAGE_MAIN")"
echo "      staged decompiled results_dialog count: $STAGE_RESULTS_COUNT"
echo "      staged exact proof property:           YES"
echo "      staged transient menu routing:         YES"
echo "      staged native true detach:             YES"
echo "      staged transient app quit:             YES"
echo "      staged showResults handler:            YES"
echo "      staged main.scpt sha256:                $STAGE_MAIN_SHA"

set_icon() {
  local app="$1" iconset="$HERE/icons/$2.iconset" icns="$HERE/icons/$2.icns"
  if command -v iconutil >/dev/null 2>&1 && [ -d "$iconset" ]; then
    iconutil -c icns "$iconset" -o "$icns" 2>/dev/null || return 0
    local existing
    existing="$(find "$app/Contents/Resources" -maxdepth 1 -name '*.icns' -print -quit 2>/dev/null || true)"
    if [ -n "$existing" ]; then cp "$icns" "$existing"; fi
  fi
}
set_icon "$STAGE_COMPRESSOR" "Compressor"
set_icon "$STAGE_DECOMPRESSOR" "Decompressor"

python3 "$HERE/configure_app.py" "$STAGE_COMPRESSOR" \
  "com.mdlbsg.compressor" "MDLBSG Compressor" --bundle-version 82 \
  || fail "could not set Compressor bundle identity"
python3 "$HERE/configure_app.py" "$STAGE_DECOMPRESSOR" \
  "com.mdlbsg.decompressor" "MDLBSG Decompressor" --register-mdl --bundle-version 82 \
  || fail "could not set Decompressor bundle identity"

resign() {
  local app="$1" out
  xattr -cr "$app" 2>/dev/null || true
  find "$app" -name $'Icon\r' -delete 2>/dev/null || true
  chmod a-w "$app/Contents/Resources/Scripts/main.scpt" 2>/dev/null || true
  if ! out="$(codesign --force --sign - "$app" 2>&1)"; then
    echo "$out" >&2
    fail "codesign failed on $(basename "$app")"
  fi
  if ! out="$(codesign --verify --strict "$app" 2>&1)"; then
    echo "$out" >&2
    fail "signature verification failed on $(basename "$app")"
  fi
  echo "      signature valid: $(basename "$app")"
}
resign "$STAGE_COMPRESSOR"
resign "$STAGE_DECOMPRESSOR"

CID="$(defaults read "$STAGE_COMPRESSOR/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo NONE)"
DID="$(defaults read "$STAGE_DECOMPRESSOR/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo NONE)"
[ "$CID" = "com.mdlbsg.compressor" ] || fail "wrong Compressor bundle ID: $CID"
[ "$DID" = "com.mdlbsg.decompressor" ] || fail "wrong Decompressor bundle ID: $DID"

echo "      staged app identities and signatures: verified"

echo "      removing known old app copies..."
for old in \
  "/Applications/MDLBSG Compressor.app" \
  "/Applications/MDLBSG Decompressor.app" \
  "$HOME/Applications/MDLBSG Compressor.app" \
  "$HOME/Applications/MDLBSG Decompressor.app" \
  "$HOME/Desktop/MDLBSG Compressor.app" \
  "$HOME/Desktop/MDLBSG Decompressor.app"
do
  if [ -e "$old" ]; then
    rm -rf "$old" 2>/dev/null || fail "could not remove old app bundle: $old"
    [ ! -e "$old" ] || fail "old app bundle survived removal: $old"
  fi
done
mkdir -p "$APPDIR"

# Install only the already-verified staged bundles. The installed file must hash
# exactly the same as the one that passed the staged proof.
mv "$STAGE_COMPRESSOR" "$COMPRESSOR_APP"
mv "$STAGE_DECOMPRESSOR" "$DECOMPRESSOR_APP"
INSTALLED_MAIN="$COMPRESSOR_APP/Contents/Resources/Scripts/main.scpt"
[ -f "$INSTALLED_MAIN" ] || fail "installed Compressor main.scpt is missing"
INSTALLED_DECOMPILED="$STAGE_ROOT/installed_compressor.decompiled.applescript"
"$OSADECOMPILE" "$INSTALLED_MAIN" > "$INSTALLED_DECOMPILED" \
  || fail "osadecompile failed for installed Compressor main.scpt"
grep -Fq "$SOURCE_MARKER" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost the exact source proof property"
grep -Fiq "on showresults" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost the showResults handler"
grep -Fq "$TRANSIENT_UI_MARKER" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost the App 81 transient-UI proof property"
grep -Fq "$TRUE_DETACH_MARKER" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost the App 82 true-detach proof property"
grep -Fq "$DETACH_NEEDLE" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost the native detached-launcher call"
grep -Fiq "quit" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost transient-app quit"
grep -Fiq "on launchmenuhelper" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost launchMenuHelper"
grep -Fq "$MENU_NEEDLE" "$INSTALLED_DECOMPILED" \
  || fail "installed compiled app lost the detached menu-helper path"
INSTALLED_RESULTS_COUNT="$(grep -Fc "$RESULTS_NEEDLE" "$INSTALLED_DECOMPILED" || true)"
[ "$INSTALLED_RESULTS_COUNT" -ge 1 ] \
  || fail "installed compiled app lost the detached results-dialog path"
INSTALLED_MAIN_SHA="$(sha256_file "$INSTALLED_MAIN")"
[ "$INSTALLED_MAIN_SHA" = "$STAGE_MAIN_SHA" ] \
  || fail "installed main.scpt does not match the verified staged main.scpt"
codesign --verify --strict "$COMPRESSOR_APP" >/dev/null 2>&1 \
  || fail "installed Compressor signature is invalid"
codesign --verify --strict "$DECOMPRESSOR_APP" >/dev/null 2>&1 \
  || fail "installed Decompressor signature is invalid"
echo "      installed app path:                        $COMPRESSOR_APP"
echo "      installed decompiled results_dialog count: $INSTALLED_RESULTS_COUNT"
echo "      installed exact proof property:            YES"
echo "      installed transient menu routing:          YES"
echo "      installed native true detach:              YES"
echo "      installed transient app quit:              YES"
echo "      installed showResults handler:             YES"
echo "      installed main.scpt sha256:                 $INSTALLED_MAIN_SHA"
echo "      staged == installed:                       YES"

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  echo "      rebuilding Launch Services registrations..."
  "$LSREG" -kill -r -domain local -domain system -domain user 2>/dev/null || true
  "$LSREG" -f "$COMPRESSOR_APP" 2>/dev/null || true
  "$LSREG" -f "$DECOMPRESSOR_APP" 2>/dev/null || true
fi
python3 "$HERE/dock_install.py" "$COMPRESSOR_APP" "$DECOMPRESSOR_APP" 2>/dev/null \
  || echo "      Dock update skipped; drag the apps from Applications to the left side of the Dock"
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "[5/6] installing the Finder Quick Action..."
mkdir -p "$HOME/Library/Services"
rm -rf "$HOME/Library/Services/Decompress with MDLBSG.workflow"
cp -R "$HERE/Decompress with MDLBSG.workflow" "$HOME/Library/Services/"
killall Finder 2>/dev/null || true

echo "[6/6] self-test: byte-perfect round trips..."
T="$(mktemp -d "${TMPDIR:-/tmp}/mdlbsg-selftest.XXXXXX")"
head -c 2000000 /dev/urandom | base64 > "$T/sample.txt"
"$HOME/.mdlbsg/bin/mdlbsg_core" --input "$T/sample.txt" --archive "$T/sample.mdl" \
  --cm-bits 24 --mm-bits 20 --chunk-bytes 1048576 --threads 4 --verify 0 \
  --warm 1 --warm-clamp 3 --warm-match 1 --layout twist --prefetch-dist 4 --prefetch-mode mtab \
  --braid 1 --rightsize 1 --w2-bits 21 --w3-bits 21 >/dev/null
"$HOME/.mdlbsg/bin/mdlbsg_core" --archive "$T/sample.mdl" --extract "$T/sample.out" --threads 4 >/dev/null
cmp "$T/sample.txt" "$T/sample.out" || fail "fast/max core roundtrip mismatch"
echo "      SELF-TEST PASSED: fast/max core"

"$HOME/.mdlbsg/bin/mdlbsg_turbo" --input "$T/sample.txt" --archive "$T/sample2.mdl" \
  --cm-bits 24 --mm-bits 22 --chunk-bytes 1048576 --threads 4 --verify 0 \
  --warm 1 --warm-clamp 3 --warm-match 1 --layout twist --prefetch-dist 4 --prefetch-mode mtab \
  --braid 1 --rightsize 1 >/dev/null
"$HOME/.mdlbsg/bin/mdlbsg_turbo" --archive "$T/sample2.mdl" --extract "$T/sample2.out" --threads 4 >/dev/null
cmp "$T/sample.txt" "$T/sample2.out" || fail "turbo core roundtrip mismatch"
echo "      SELF-TEST PASSED: turbo core"

DL="$HOME/Downloads"; mkdir -p "$DL"
cp "$T/sample.txt" "$DL/mdlbsg_selftest_sample.txt"
bash "$HOME/.mdlbsg/bin/mdlbsg_droplet_handler.sh" "$DL/mdlbsg_selftest_sample.txt" >/dev/null
bash "$HOME/.mdlbsg/bin/mdlbsg_droplet_handler.sh" "$DL/mdlbsg_selftest_sample.txt.mdl" >/dev/null
cmp "$T/sample.txt" "$DL/mdlbsg_selftest_sample.txt" || fail "drag-and-drop pipeline roundtrip mismatch"
echo "      SELF-TEST PASSED: drag-and-drop pipeline"

"$HOME/.mdlbsg/bin/mdlbsg" c "$T/sample.txt" "$DL/mdlbsg_selftest_sample2.txt.mdl" -p max >/dev/null
bash "$HOME/.mdlbsg/bin/mdlbsg_extract_handler.sh" "$DL/mdlbsg_selftest_sample2.txt.mdl" >/dev/null
cmp "$T/sample.txt" "$DL/mdlbsg_selftest_sample2.txt" || fail "decompressor-only pipeline mismatch"
echo "      SELF-TEST PASSED: decompressor-only pipeline"

if bash "$HOME/.mdlbsg/bin/mdlbsg_extract_handler.sh" "$T/sample.txt" >/dev/null 2>&1; then
  fail "decompressor accepted a non-archive file"
fi
echo "      SELF-TEST PASSED: decompressor rejects non-archives"
rm -f "$DL/mdlbsg_selftest_sample2.txt.mdl" "$DL/mdlbsg_selftest_sample2.txt"
rm -f "$DL/mdlbsg_selftest_sample.txt" "$DL/mdlbsg_selftest_sample.txt.mdl"
rm -rf "$T"

BUILD_INFO_TMP="$HOME/.mdlbsg/bin/BUILD_INFO.tmp.$$"
{
  echo "built: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "app_version: $APP_VERSION"
  echo "package_marker: $PACKAGE_MARKER"
  echo "installer_path: $HERE/INSTALL_MDLBSG.command"
  echo "compressor_source: $SOURCE"
  echo "compressor_source_sha256: $SOURCE_SHA"
  echo "installed_app: $COMPRESSOR_APP"
  echo "compiled_main_scpt_sha256: $INSTALLED_MAIN_SHA"
  echo "decompiled_results_dialog_count: $INSTALLED_RESULTS_COUNT"
  echo "staged_equals_installed: YES"
  echo "transient_ui: detached launcher helper"
  echo "results_detach: native double-fork launcher"
  echo "transient_app_quit: YES"
  echo "detached_launcher_selftest: PASS"
  echo "progress_owner: transient Compressor app (forced quit after handoff)"
  echo "compressor_bundle_id: $CID"
  echo "decompressor_bundle_id: $DID"
  echo "core_src_sha256: $(sha256_file "$HERE/src/mdlbsg_app.cpp")"
  echo "turbo_src_sha256: $(sha256_file "$HERE/src/mdlbsg_turbo_app.cpp")"
} > "$BUILD_INFO_TMP"
mv "$BUILD_INFO_TMP" "$HOME/.mdlbsg/bin/BUILD_INFO"

echo
echo "============================================================"
echo " INSTALL VERIFIED — this is not a version-stamp-only success"
echo "============================================================"
echo "Installed bundle: $COMPRESSOR_APP"
echo "osadecompile results_dialog count: $INSTALLED_RESULTS_COUNT"
echo "compiled source hash matches staged build: YES"
echo
echo "Now test the actual macOS behavior:"
echo "  1. Drag one file onto MDLBSG Compressor."
echo "  2. Leave its results popup open."
echo "  3. Drag a second file onto MDLBSG Compressor."
echo "The progress window must disappear after handoff; the second compression must start immediately while the first popup remains open."
