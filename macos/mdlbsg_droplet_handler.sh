#!/usr/bin/env bash
# mdlbsg_droplet_handler.sh — the logic behind the drag-and-drop app.
# Given one file path: detects compress-vs-decompress by magic bytes, runs the right
# core, writes output to ~/Downloads with Finder-style de-duplication, prints a summary.
set -uo pipefail
IN="$1"
PROGRESS_FILE="${2:-}"   # optional: core writes "<done> <total>" here so a bar can be drawn
DEST_ARG="${3:-}"        # optional: where to save; overrides the default
BIN_DIR="$HOME/.mdlbsg/bin"
if [ -n "$DEST_ARG" ]; then
  DOWNLOADS="$DEST_ARG"
elif [ -s "$HOME/.mdlbsg/destdir" ]; then
  DOWNLOADS="$(cat "$HOME/.mdlbsg/destdir")"
else
  DOWNLOADS="$HOME/Downloads"
fi

[ -e "$IN" ] || { echo "ERROR: not found: $IN"; exit 1; }
[ -x "$BIN_DIR/mdlbsg" ] || { echo "ERROR: mdlbsg is not installed — run INSTALL_MDLBSG.command first."; exit 1; }
mkdir -p "$DOWNLOADS" 2>/dev/null || true

IS_DIR=false
if [ -d "$IN" ]; then IS_DIR=true; fi
IN_NOSLASH="${IN%/}"
BASE="$(basename "$IN_NOSLASH")"
if $IS_DIR; then MAGIC=""; else MAGIC="$(head -c 8 "$IN" 2>/dev/null || true)"; fi


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

case "$MAGIC" in
  MDLB301A|MDLB301F|MDLBTURA|MDLBTURF|MDL16URA|MDL16URF|MDLBSTOR|MDLBSTOF|MDLBSGv2) IS_ARCHIVE=1 ;;
  *) IS_ARCHIVE=0 ;;
esac
if [ "$IS_ARCHIVE" = "1" ]; then
  if [[ "$BASE" == *.mdl ]]; then OUTBASE="${BASE%.mdl}"; else OUTBASE="${BASE}.restored"; fi
  OUTPATH="$(uniquify "$OUTBASE")"
  if ! RESULT="$("$BIN_DIR/mdlbsg" d "$IN" "$OUTPATH" 2>&1)"; then
    echo "ERROR decompressing $BASE:"$'\n'"$RESULT"; exit 1
  fi
  OUTSIZE=$(stat -f%z "$OUTPATH" 2>/dev/null || stat -c%s "$OUTPATH" 2>/dev/null || echo "?")
  echo "Decompressed: $BASE -> $(basename "$OUTPATH")  (${OUTSIZE} bytes)"
elif $IS_DIR; then
  FILECOUNT=$(find "$IN_NOSLASH" -type f | wc -l | tr -d ' ')
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT   # cancelled/killed runs must not leak multi-GB tarballs
  TARBALL="$TMPD/${BASE}.tar"
  # PREFLIGHT: bundling needs ~folder-size free where the tarball lives. Finding out
  # via a mid-write tar error 34,000 files in is the worst way; check first and say
  # exactly what's missing and how to free it.
  FOLDER_KB=$(du -sk "$IN_NOSLASH" 2>/dev/null | cut -f1); FOLDER_KB=${FOLDER_KB:-0}
  FREE_KB=$(df -k "$TMPD" | awk 'NR==2 {print $4}'); FREE_KB=${FREE_KB:-0}
  NEED_KB=$(( FOLDER_KB + FOLDER_KB / 5 ))   # +20% headroom
  if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    echo "ERROR: not enough free disk space to bundle \"$BASE\"."
    echo "Needs about $(( NEED_KB / 1048576 )) GB free; this disk has $(( FREE_KB / 1048576 )) GB."
    echo "To free space quickly: run 'mdlbsg cache clear' in Terminal, or empty the Trash."
    exit 1
  fi
  # macOS's tar exits non-zero for harmless WARNINGS too -- an unreadable extended
  # attribute, a file touched mid-read, a socket in the tree. Treating that as failure
  # rejected perfectly good folders. So: judge the RESULT, not the exit code, and if it
  # really did fail, show tar's actual words instead of a useless generic message.
  # COPYFILE_DISABLE stops macOS from injecting ._ AppleDouble metadata files.
  TAR_ERR="$(COPYFILE_DISABLE=1 tar -cf "$TARBALL" -C "$(dirname "$IN_NOSLASH")" "$BASE" 2>&1 || true)"
  # Completeness check: a tar that died partway can still LIST fine, so compare the
  # entry count against the folder itself. Never compress a bundle that lost files.
  TAR_FILES=$(tar -tf "$TARBALL" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')
  [ -n "$TAR_FILES" ] || TAR_FILES=0
  if [ ! -s "$TARBALL" ] || [ "$TAR_FILES" -lt "$FILECOUNT" ]; then
    rm -rf "$TMPD"
    if echo "$TAR_ERR" | grep -qiE "no space|write error"; then
      echo "ERROR: the disk filled up while bundling \"$BASE\" ($TAR_FILES of $FILECOUNT files bundled)."
      echo "To free space quickly: run 'mdlbsg cache clear' in Terminal, or empty the Trash, then try again."
    else
      echo "ERROR: couldn't bundle the folder \"$BASE\" ($TAR_FILES of $FILECOUNT files bundled)"
      [ -n "$TAR_ERR" ] && echo "$TAR_ERR" | head -5
    fi
    exit 1
  fi
  OUTPATH="$(uniquify "${BASE}.mdl")"
  PROG_ARGS=()
  [ -n "$PROGRESS_FILE" ] && PROG_ARGS=(--progress-file "$PROGRESS_FILE")
  if ! RESULT="$("$BIN_DIR/mdlbsg" c "$TARBALL" "$OUTPATH" --content folder ${PROG_ARGS[@]:+"${PROG_ARGS[@]}"} 2>&1)"; then
    rm -rf "$TMPD"; echo "ERROR compressing folder $BASE:"$'\n'"$RESULT"; exit 1
  fi
  IB=$(echo "$RESULT" | grep -o 'input_bytes=[0-9]*' | cut -d= -f2)
  AB=$(echo "$RESULT" | grep -o 'archive_bytes=[0-9]*' | cut -d= -f2)
  rm -rf "$TMPD"
  if [ ! -f "$OUTPATH" ]; then
    echo "SAVE_FAILED: compression finished but the archive could not be written to $DOWNLOADS"
    echo "$RESULT" | grep -iE "error|denied|permission|space" | head -2
    exit 3
  fi
  WS=$(echo "$RESULT" | grep -o 'wall_seconds=[0-9.]*' | cut -d= -f2)
  if [ -n "${IB:-}" ] && [ -n "${AB:-}" ] && [ "$IB" -gt 0 ] && [ "$AB" -lt "$IB" ]; then
    PCT=$(( 100 - (AB * 100 / IB) ))
    echo "Compressed folder: $BASE ($FILECOUNT files)"
    echo "Saved to: $OUTPATH"
    echo "${PCT}% smaller: $(commas "$IB") bytes -> $(commas "$AB") bytes"
    [ -n "${WS:-}" ] && echo "Took $(fmt_secs "$WS") at $(speed_of "$IB" "$WS")"
  else
    echo "Compressed folder: $BASE ($FILECOUNT files) -> $(basename "$OUTPATH")"
  fi
else
  OUTBASE="${BASE}.mdl"
  OUTPATH="$(uniquify "$OUTBASE")"
  PROG_ARGS=()
  [ -n "$PROGRESS_FILE" ] && PROG_ARGS=(--progress-file "$PROGRESS_FILE")
  if ! RESULT="$("$BIN_DIR/mdlbsg" c "$IN" "$OUTPATH" ${PROG_ARGS[@]:+"${PROG_ARGS[@]}"} 2>&1)"; then
    echo "ERROR compressing $BASE:"$'\n'"$RESULT"; exit 1
  fi
  if echo "$RESULT" | grep -q "stored_fallback=true"; then
    echo "Compressed: $BASE -> $(basename "$OUTPATH")  (too small/incompressible to shrink — kept as-is, safe to send around)"
  else
    IB=$(echo "$RESULT" | grep -o 'input_bytes=[0-9]*' | cut -d= -f2)
    AB=$(echo "$RESULT" | grep -o 'archive_bytes=[0-9]*' | cut -d= -f2)
    WS=$(echo "$RESULT" | grep -o 'wall_seconds=[0-9.]*' | cut -d= -f2)
    if [ -n "${IB:-}" ] && [ -n "${AB:-}" ] && [ "$IB" -gt 0 ] && [ "$AB" -lt "$IB" ]; then
      PCT=$(( 100 - (AB * 100 / IB) ))
      echo "Compressed: $BASE"
      echo "Saved to: $OUTPATH"
      echo "${PCT}% smaller: $(commas "$IB") bytes -> $(commas "$AB") bytes"
      [ -n "${WS:-}" ] && echo "Took $(fmt_secs "$WS") at $(speed_of "$IB" "$WS")"
    else
      echo "Compressed: $BASE -> $(basename "$OUTPATH")"
    fi
  fi
fi
