#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${HARBOR_TOOL_RUNTIME_DIR:-$HOME/Library/Application Support/MVD/Runtime}"
runtime_python="$runtime_root/python"
python3 -m venv "$runtime_python"
"$runtime_python/bin/python" -m pip install -r "$project_root/Scripts/media-requirements.txt"
"$runtime_python/bin/yt-dlp" --version
echo "yt-dlp and EJS are ready in $runtime_python. FFmpeg and Deno are discovered separately."
echo 'The runtime is kept outside protected project folders so GUI-launched Python can initialize normally.'
