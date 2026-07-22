#!/usr/bin/env bash
# INSTALL_MDLBSG_LINUX.sh — MDLBSG on Linux.
# Builds both cores from the same source the Mac uses, installs the mdlbsg CLI,
# and proves the install with byte-perfect roundtrips before saying "done".
#
#   bash INSTALL_MDLBSG_LINUX.sh
#
# No sudo needed. Everything lives in ~/.mdlbsg; the CLI goes on your PATH.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.mdlbsg/bin"
mkdir -p "$BIN"

echo "[1/4] checking for a C++ compiler..."
CXX=""
for c in g++ clang++; do
  if command -v "$c" >/dev/null 2>&1; then CXX="$c"; break; fi
done
if [ -z "$CXX" ]; then
  echo "  No C++ compiler found. Install one and re-run:"
  echo "    Debian/Ubuntu:  sudo apt install g++"
  echo "    Fedora:         sudo dnf install gcc-c++"
  echo "    Arch:           sudo pacman -S gcc"
  exit 1
fi
echo "      using $CXX ($($CXX --version | head -1))"

echo "[2/4] building both cores (same source as the Mac build)..."
# -march=native for full speed on THIS machine; falls back to generic if the
# flag is unsupported (some containers/VMs).
$CXX -O3 -march=native -std=c++17 -pthread -o "$BIN/mdlbsg_core"  "$HERE/src/mdlbsg_app.cpp" 2>/dev/null \
  || $CXX -O3 -std=c++17 -pthread -o "$BIN/mdlbsg_core"  "$HERE/src/mdlbsg_app.cpp"
$CXX -O3 -march=native -std=c++17 -pthread -o "$BIN/mdlbsg_turbo" "$HERE/src/mdlbsg_turbo_app.cpp" 2>/dev/null \
  || $CXX -O3 -std=c++17 -pthread -o "$BIN/mdlbsg_turbo" "$HERE/src/mdlbsg_turbo_app.cpp"
echo "      built: $BIN/mdlbsg_core"
echo "      built: $BIN/mdlbsg_turbo"
{
  echo "built: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "core_src_sha256:  $(sha256sum "$HERE/src/mdlbsg_app.cpp" | cut -d' ' -f1)  (mdlbsg_app.cpp)"
  echo "turbo_src_sha256: $(sha256sum "$HERE/src/mdlbsg_turbo_app.cpp" | cut -d' ' -f1)  (mdlbsg_turbo_app.cpp, v234 lineage)"
} > "$BIN/BUILD_INFO"

echo "[3/4] installing the mdlbsg command..."
cp "$HERE/mdlbsg" "$BIN/mdlbsg"; chmod +x "$BIN/mdlbsg"
cp "$HERE/mdlbsg_extract_handler.sh" "$BIN/"; chmod +x "$BIN/mdlbsg_extract_handler.sh"
cp "$HERE/mdlbsg_droplet_handler.sh" "$BIN/"; chmod +x "$BIN/mdlbsg_droplet_handler.sh"
# PATH: add once to whichever shell rc files exist (bash and zsh both covered).
ADDED=""
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$RC" ] || continue
  if ! grep -q '.mdlbsg/bin' "$RC" 2>/dev/null; then
    echo 'export PATH="$HOME/.mdlbsg/bin:$PATH"' >> "$RC"
    ADDED="$ADDED $(basename "$RC")"
  fi
done
if [ -n "$ADDED" ]; then
  echo "      PATH updated in:$ADDED (open a new terminal, or: export PATH=\"\$HOME/.mdlbsg/bin:\$PATH\")"
else
  echo "      PATH already set up"
fi

echo "[4/4] self-test: byte-perfect roundtrip on both cores..."
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
head -c 2000000 /dev/urandom | base64 > "$T/sample.txt"
"$BIN/mdlbsg_core" --input "$T/sample.txt" --archive "$T/s.mdl" \
  --cm-bits 24 --mm-bits 20 --chunk-bytes 1048576 --threads 4 --verify 0 \
  --warm 1 --warm-clamp 3 --warm-match 1 --layout twist --prefetch-dist 4 --prefetch-mode mtab \
  --braid 1 --rightsize 1 --w2-bits 21 --w3-bits 21 >/dev/null
"$BIN/mdlbsg_core" --archive "$T/s.mdl" --extract "$T/s.out" --threads 4 >/dev/null
cmp "$T/sample.txt" "$T/s.out" && echo "      SELF-TEST PASSED (fast/max core): byte-perfect roundtrip."
"$BIN/mdlbsg_turbo" --input "$T/sample.txt" --archive "$T/t.mdl" \
  --cm-bits 24 --mm-bits 22 --chunk-bytes 1048576 --threads 4 --verify 0 \
  --warm 1 --warm-clamp 3 --warm-match 1 --layout twist --prefetch-dist 4 --prefetch-mode mtab \
  --braid 1 --rightsize 1 >/dev/null
"$BIN/mdlbsg_turbo" --archive "$T/t.mdl" --extract "$T/t.out" --threads 4 >/dev/null
cmp "$T/sample.txt" "$T/t.out" && echo "      SELF-TEST PASSED (turbo core): byte-perfect roundtrip."

echo ""
echo "Done. Usage is identical to the Mac CLI:"
echo "  mdlbsg c <file|folder>      compress (turbo by default)"
echo "  mdlbsg d <archive.mdl>      decompress"
echo "  mdlbsg mode max             switch default mode"
echo ""
echo "Archives are cross-platform: compress on the Mac, extract on Linux, and back."
