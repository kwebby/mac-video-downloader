#!/bin/bash
set -euo pipefail
preview_root="$(cd "$(dirname "$0")/../.." && pwd)"
preview_theme="${1:-light}"
case "$preview_theme" in light|dark|system|custom) ;; *) echo 'Theme must be light, dark, system, or custom.' >&2; exit 2 ;; esac
preview_app="$preview_root/build/DesignPreview/MVD Design Preview.app"
if [[ ! -x "$preview_app/Contents/MacOS/MVDDesignPreview" ]]; then
    echo 'Run python3 Tests/DesignPreview/build.py first.' >&2
    exit 2
fi
preview_support="$(mktemp -d "${TMPDIR:-/tmp/}mvd-design-preview.XXXXXX")"
env HARBOR_SUPPORT_DIR="$preview_support" \
    MVD_PREVIEW_FIXTURES="$preview_root/Tests/DesignPreview/fixtures" \
    MVD_PREVIEW_THEME="$preview_theme" \
    MVD_PREVIEW_WIDTH="${2:-1440}" \
    MVD_PREVIEW_HEIGHT="${3:-920}" \
    MVD_PREVIEW_FONT_SIZE="${MVD_PREVIEW_FONT_SIZE:-13}" \
    "$preview_app/Contents/MacOS/MVDDesignPreview" >"$preview_support/preview.log" 2>&1 </dev/null &
preview_pid=$!
echo "Preview PID: $preview_pid"
echo "Isolated state/log: $preview_support"
echo "App: $preview_app"
wait "$preview_pid"
