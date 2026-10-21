#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${MVD_BUILD_CONFIGURATION:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    echo 'MVD_BUILD_CONFIGURATION must be debug or release.' >&2
    exit 2
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="${MVD_BUILD_APP_DIR:-$project_root/build/MVD.app}"
if [[ "$app_dir" != /* || "$app_dir" != *.app ]]; then
    echo 'MVD_BUILD_APP_DIR must be an absolute .app path.' >&2
    exit 2
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Harbor" "$app_dir/Contents/MacOS/MVD"
for product in HarborBroker HarborNativeHost harborctl; do
    cp "$binary_dir/$product" "$app_dir/Contents/MacOS/$product"
done
swift Scripts/make-icon.swift "$project_root/build/BrandAssets"
cp "$project_root/build/BrandAssets/MVDIcon.icns" "$app_dir/Contents/Resources/"
cp "$project_root/build/BrandAssets/MVDMark.png" "$app_dir/Contents/Resources/"
cp "$project_root/Assets/mvd-download.svg" "$app_dir/Contents/Resources/"
# Keep the setup payload inside the app so Chrome can be connected after the
# disk image is ejected. Installation is an explicit action in MVD's interface.
"$project_root/Scripts/package-extension.sh"
python3 - "$project_root/build/Chrome Companion" "$app_dir/Contents/Resources/Chrome Companion" <<'PY'
from pathlib import Path
import shutil
import sys
source, destination = map(Path, sys.argv[1:])
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, symlinks=True)
PY
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MVD</string>
<key>CFBundleIdentifier</key><string>io.harbor.downloads.dev</string>
<key>CFBundleName</key><string>MVD</string>
<key>CFBundleDisplayName</key><string>MVD</string>
<key>CFBundleIconFile</key><string>MVDIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.4</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>io.harbor.downloads.review</string>
<key>CFBundleURLSchemes</key><array><string>harbor-downloads</string></array>
</dict></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
export HARBOR_BUILD_PROJECT_ROOT="$project_root"
export HARBOR_BUILD_APP_DIR="$app_dir"
python3 - <<'PY'
import json, os, pathlib, shutil
root = pathlib.Path(os.environ['HARBOR_BUILD_PROJECT_ROOT'])
app = pathlib.Path(os.environ['HARBOR_BUILD_APP_DIR'])
paths = {}
runtime = pathlib.Path(os.environ.get('HARBOR_TOOL_RUNTIME_DIR', pathlib.Path.home() / 'Library/Application Support/MVD/Runtime'))
for key, name, candidates in [
    ('HARBOR_YTDLP_PATH', 'yt-dlp', [runtime / 'python/bin/yt-dlp', root / '.tools/python/bin/yt-dlp']),
    ('HARBOR_FFMPEG_PATH', 'ffmpeg', [pathlib.Path('/opt/homebrew/bin/ffmpeg')]),
    ('HARBOR_DENO_PATH', 'deno', [pathlib.Path('/opt/homebrew/bin/deno')]),
]:
    value = os.environ.get(key)
    if value:
        paths[key] = value
    elif fallback := next((candidate for candidate in candidates if candidate.is_file()), None):
        paths[key] = str(fallback)
    elif found := shutil.which(name):
        paths[key] = found
(app / 'Contents/Resources/runtime.json').write_text(json.dumps(paths, indent=2))
PY
for product in HarborBroker HarborNativeHost harborctl MVD; do
    codesign --force --sign - "$app_dir/Contents/MacOS/$product"
done
codesign --force --sign - "$app_dir"
echo "$app_dir"
echo 'Local development build: media tools are referenced on this Mac, not bundled for distribution.'
