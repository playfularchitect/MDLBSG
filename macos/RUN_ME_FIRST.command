#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$HERE/INSTALL_APP91_APPLET_RUN_HANDLER_FIX.command"
exec /bin/bash "$HERE/INSTALL_APP91_APPLET_RUN_HANDLER_FIX.command"
