#!/usr/bin/env bash
# mdlbsg_extract_handler.sh — logic behind the decompress-only drag-and-drop app.
# Given one file path: if it's a real MDLBSG archive, decompresses it to ~/Downloads
# with Finder-style de-duplication. If it's not an archive, says so clearly and stops
# (this app never compresses — that's the other app's job).
set -uo pipefail
IN="$1"
PROGRESS_FILE="${2:-}"   # optional: core writes "<done> <total>" here so a bar can be drawn
DEST_ARG="${3:-}"        # optional: where to save; overrides the default
BIN_DIR="$HOME/.mdlbsg/bin"
# Where output goes: explicit argument > remembered choice > Downloads.
if [ -n "$DEST_ARG" ]; then
  DOWNLOADS="$DEST_ARG"
elif [ -s "$HOME/.mdlbsg/destdir" ]; then
  DOWNLOADS="$(cat "$HOME/.mdlbsg/destdir")"
else
  DOWNLOADS="$HOME/Downloads"
fi

[ -f "$IN" ] || { echo "ERROR: file not found: $IN"; exit 1; }
[ -x "$BIN_DIR/mdlbsg" ] || { echo "ERROR: mdlbsg is not installed — run INSTALL_MDLBSG.command first."; exit 1; }
mkdir -p "$DOWNLOADS" 2>/dev/null || true

BASE="$(basename "$IN")"
MAGIC="$(head -c 8 "$IN" 2>/dev/null || true)"

case "$MAGIC" in
  MDLB301A|MDLBTURA|MDL16URA|MDLBSTOR) IS_FOLDER_ARCHIVE=false ;;
  MDLB301F|MDLBTURF|MDL16URF|MDLBSTOF) IS_FOLDER_ARCHIVE=true ;;
  MDLBSGv2)
    # v2 wraps a v1 archive after a 24-byte header; the inner magic still carries
    # the folder/file marker in its last letter (A=file, F=folder).
    INNER="$(dd if="$IN" bs=1 skip=24 count=8 2>/dev/null || true)"
    case "$INNER" in
      *F) IS_FOLDER_ARCHIVE=true ;;
      *)  IS_FOLDER_ARCHIVE=false ;;
    esac ;;
  *) echo "ERROR: \"$BASE\" doesn't look like an MDLBSG archive (no recognized header) — nothing to decompress."; exit 1 ;;
esac


# Throughput, computed from what the core already reports. Shared by the app and the CLI.
commas() {  # 1234567 -> 1,234,567 (portable; printf %'d is locale-dependent)
  awk -v n="$1" 'BEGIN {
    s = sprintf("%d", n); out = ""; c = 0
    for (i = length(s); i >= 1; i--) {
      out = substr(s, i, 1) out; c++
      if (c % 3 == 0 && i > 1) out = "," out
    }
    print out
  }'
}

speed_of() {  # $1 = bytes, $2 = seconds -> "12.4 MB/s"
  awk -v b="$1" -v s="$2" 'BEGIN {
    if (s <= 0) { printf "" } else { printf "%.2f MB/s", (b / 1048576) / s }
  }'
}
fmt_secs() {  # $1 = seconds -> "1m 12s"
  awk -v s="$1" 'BEGIN {
    s = int(s + 0.5);
    if (s < 60) { printf "%ds", s }
    else if (s < 3600) { printf "%dm %ds", int(s/60), s%60 }
    else { printf "%dh %dm", int(s/3600), int((s%3600)/60) }
  }'
}

uniquify() {  # $1 = desired filename (no dir) -> echoes a Downloads path that doesn't collide
  local base="$1" name="$1" n=2
  while [ -e "$DOWNLOADS/$name" ]; do
    if [[ "$base" == *.* ]]; then
      local stem="${base%.*}" ext="${base##*.}"
      name="${stem} (${n}).${ext}"
    else
      name="${base} (${n})"
    fi
    n=$((n+1))
  done
  echo "$DOWNLOADS/$name"
}

if [[ "$BASE" == *.mdl ]]; then OUTBASE="${BASE%.mdl}"; else OUTBASE="${BASE}.restored"; fi

DPROG=()
[ -n "$PROGRESS_FILE" ] && DPROG=(--progress-file "$PROGRESS_FILE")

if $IS_FOLDER_ARCHIVE; then
  # Unpack through a temp area so the bundle never occupies the folder's own name.
  TMPD="$(mktemp -d)"
  TARPATH="$TMPD/bundle.tar"
  if ! RESULT="$("$BIN_DIR/mdlbsg" d "$IN" "$TARPATH" ${DPROG[@]:+"${DPROG[@]}"} 2>&1)"; then
    rm -rf "$TMPD"; echo "ERROR decompressing $BASE:"$'\n'"$RESULT"; exit 1
  fi
  XDIR="$TMPD/x"; mkdir -p "$XDIR"
  # Judge the RESULT, not tar's exit code. macOS tar exits non-zero for harmless
  # warnings -- an extended attribute it can't restore, a ._ file, a permission
  # nuance -- and treating that as failure threw away files that had extracted
  # perfectly. If tar genuinely failed, show its actual words.
  TAR_ERR="$(tar -xf "$TARPATH" -C "$XDIR" 2>&1 || true)"
  TOP="$(ls "$XDIR" 2>/dev/null | head -1)"
  if [ -z "$TOP" ]; then
    rm -rf "$TMPD"
    echo "ERROR: the archive's folder contents could not be unpacked"
    [ -n "$TAR_ERR" ] && echo "$TAR_ERR" | head -5
    exit 1
  fi
  DEST="$(uniquify "$TOP")"
  MV_ERR="$(mv "$XDIR/$TOP" "$DEST" 2>&1 || true)"
  rm -rf "$TMPD"
  # Never claim success without confirming the result exists on disk.
  if [ ! -d "$DEST" ]; then
    # SAVE_FAILED is a marker the app watches for, so it can offer another location.
    echo "SAVE_FAILED: the folder was restored but could not be written to $DOWNLOADS"
    [ -n "$MV_ERR" ] && echo "Reason: $MV_ERR"
    exit 3
  fi
  NFILES=$(find "$DEST" -type f | wc -l | tr -d ' ')
  WS=$(echo "$RESULT" | grep -o 'wall_seconds=[0-9.]*' | cut -d= -f2)
  RB=$(echo "$RESULT" | grep -o 'extracted_bytes=[0-9]*' | cut -d= -f2)
  echo "Restored folder: $BASE ($NFILES files)"
  echo "Saved to: $DEST"
  [ -n "${WS:-}" ] && [ -n "${RB:-}" ] && echo "Took $(fmt_secs "$WS") at $(speed_of "$RB" "$WS")"
  exit 0
fi

OUTPATH="$(uniquify "$OUTBASE")"
if ! RESULT="$("$BIN_DIR/mdlbsg" d "$IN" "$OUTPATH" ${DPROG[@]:+"${DPROG[@]}"} 2>&1)"; then
  echo "ERROR decompressing $BASE:"$'\n'"$RESULT"; exit 1
fi
if [ ! -f "$OUTPATH" ]; then
  echo "SAVE_FAILED: the file was restored but could not be written to $DOWNLOADS"
  echo "$RESULT" | grep -iE "error|denied|permission|space" | head -2
  exit 3
fi
OUTSIZE=$(stat -f%z "$OUTPATH" 2>/dev/null || stat -c%s "$OUTPATH" 2>/dev/null || echo "?")
WS=$(echo "$RESULT" | grep -o 'wall_seconds=[0-9.]*' | cut -d= -f2)
echo "Restored: $BASE"
echo "Saved to: $OUTPATH"
echo "$(commas "$OUTSIZE") bytes"
[ -n "${WS:-}" ] && [ "$OUTSIZE" != "?" ] && echo "Took $(fmt_secs "$WS") at $(speed_of "$OUTSIZE" "$WS")"
