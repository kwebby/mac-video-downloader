#!/usr/bin/env python3
"""Build a separate nonshipping app from MVD's real UI sources."""
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = ROOT / "build/DesignPreview"
APP = BUILD / "MVD Design Preview.app"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT)


def fetch_fixtures():
    folder = HERE / "fixtures"
    folder.mkdir(exist_ok=True)
    files = {
        "sample.mp4": "https://www.w3schools.com/html/mov_bbb.mp4",
        "sample.mp3": "https://www.w3schools.com/html/horse.mp3",
        "big-buck-bunny.jpg": "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg",
        "planet-earth.jpg": "https://i.ytimg.com/vi/6v2L2UGZJAM/hqdefault.jpg",
        "tears-of-steel.jpg": "https://i.ytimg.com/vi/R6MlUcmOul8/hqdefault.jpg",
    }
    for filename, url in files.items():
        target = folder / filename
        if target.is_file() and target.stat().st_size:
            continue
        staging = target.with_suffix(target.suffix + ".partial")
        run("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--user-agent", "Mozilla/5.0", "--max-time", "45", url, "--output", staging)
        staging.replace(target)


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    fetch_fixtures()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    common = ["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx14.0", "-sdk", sdk, "-module-cache-path", str(BUILD / "ModuleCache")]
    # Independent core module avoids taking SwiftPM's build lock or modifying
    # the production app. Compile this only after another UI build is idle.
    core_sources = sorted((ROOT / "Sources/HarborCore").glob("*.swift"))
    core_object = BUILD / "HarborCore.o"
    core_module = BUILD / "HarborCore.swiftmodule"
    if not core_object.exists() or not core_module.exists() or max(path.stat().st_mtime for path in core_sources) > min(core_object.stat().st_mtime, core_module.stat().st_mtime):
        run(*common, "-parse-as-library", "-whole-module-optimization", "-module-name", "HarborCore", "-emit-module", "-emit-module-path", core_module, "-emit-object", *core_sources, "-o", core_object)
    app_source = (ROOT / "Sources/HarborApp/HarborApp.swift").read_text()
    commands = app_source.split("struct HarborCommands: Commands {", 1)[1].split("struct HarborMenuBar: View {", 1)[0]
    command_file = BUILD / "HarborCommands.swift"
    command_file.write_text("import AppKit\nimport HarborCore\nimport SwiftUI\n\nstruct HarborCommands: Commands {" + commands)
    macos = APP / "Contents/MacOS"
    resources = APP / "Contents/Resources"
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    ui_sources = [path for path in sorted((ROOT / "Sources/HarborApp").glob("*.swift")) if path.name != "HarborApp.swift"]
    run(*common, "-parse-as-library", "-whole-module-optimization", "-module-name", "MVDDesignPreview", "-I", BUILD, *ui_sources, command_file, HERE / "LibraryPreview.swift", core_object, "-o", macos / "MVDDesignPreview")
    for name in ["MVDIcon.icns", "MVDMark.png"]:
        source = ROOT / "build/BrandAssets" / name
        if source.exists():
            shutil.copy2(source, resources / name)
    shutil.copy2(ROOT / "Assets/mvd-download.svg", resources / "mvd-download.svg")
    # Intentionally omit brokers, native hosts, runtime.json, URL schemes, and
    # installable extension payloads. Setup cannot target this preview bundle.
    plist = {"CFBundleExecutable": "MVDDesignPreview", "CFBundleIdentifier": "io.harbor.downloads.designpreview", "CFBundleName": "MVD Design Preview", "CFBundleDisplayName": "MVD Design Preview", "CFBundleIconFile": "MVDIcon", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication"}
    (APP / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
    run("/usr/bin/codesign", "--force", "--sign", "-", APP)
    print(APP)


if __name__ == "__main__":
    main()
