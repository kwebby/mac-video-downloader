#!/usr/bin/env python3
"""Create a portable Developer-ID-signed DMG; optionally notarize and staple.

Credentials stay in Keychain. Set MVD_NOTARY_PROFILE to a stored notarytool
profile, and optionally MVD_SIGNING_IDENTITY to an exact certificate SHA-1/name.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/Release/MVD.app"
REPORTS = ROOT / "build/ReleaseReports"
DIST = ROOT / "dist"
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf"}


def run(*args, capture=False, **kwargs):
    try:
        return subprocess.run([str(a) for a in args], check=True, text=True,
                              stdout=subprocess.PIPE if capture else None,
                              stderr=subprocess.PIPE if capture else None, **kwargs)
    except subprocess.CalledProcessError as error:
        if capture and error.stderr:
            print(error.stderr, file=sys.stderr)
        raise


def signing_identity():
    listing = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).stdout
    identities = re.findall(r'([A-F0-9]{40}) "(Developer ID Application: [^"]+)"', listing)
    requested = os.environ.get("MVD_SIGNING_IDENTITY")
    if requested:
        identities = [entry for entry in identities if requested in entry]
    if len(identities) != 1:
        raise SystemExit("Choose one valid Developer ID Application identity using MVD_SIGNING_IDENTITY.")
    return identities[0]


def machos(directory):
    result = []
    for file in directory.rglob("*"):
        if file.is_symlink():
            if not file.resolve().is_relative_to(directory.resolve()):
                raise SystemExit(f"Bundle symlink escapes its root: {file}")
            continue
        if not file.is_file():
            continue
        with file.open("rb") as stream:
            if stream.read(4) not in MAGIC:
                continue
        description = run("file", "-b", file, capture=True).stdout
        if "object" not in description:
            result.append(file)
    return sorted(result, key=lambda file: len(file.parts), reverse=True)


def copy_tree(source, destination):
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)


def assemble():
    resources = APP / "Contents/Resources"
    runtime = ROOT / "build/PortableRuntime"
    media = ROOT / "Packaging/Runtime/output/arm64"
    for required in [APP, runtime / "Tools", media / "bin/ffmpeg", media / "bin/ffprobe",
                     ROOT / "Packaging/Runtime/python-notices/license-report.json",
                     ROOT / "Packaging/Runtime/deno-notices/provenance.json",
                     ROOT / "Packaging/Runtime/deno-notices/gaps.json"]:
        if not required.exists():
            raise SystemExit(f"Missing release input: {required}")
    copy_tree(runtime / "Tools", resources / "Tools")
    for name in ["ffmpeg", "ffprobe"]:
        shutil.copy2(media / "bin" / name, resources / "Tools" / name)
    # Development headers/object files are never executable release payloads.
    for folder in (resources / "Tools/Python/lib/python3.14").glob("config-*"):
        if folder.is_dir():
            shutil.rmtree(folder)
    copy_tree(runtime / "Licenses", resources / "Licenses")
    copy_tree(media / "licenses", resources / "Licenses/Media")
    copy_tree(ROOT / "Packaging/Runtime/python-notices", resources / "Licenses/Python-dependencies")
    deno_notices = ROOT / "Packaging/Runtime/deno-notices"
    copy_tree(deno_notices, resources / "Licenses/Deno-dependencies")
    run(ROOT / "Scripts/package-extension.sh")
    copy_tree(ROOT / "build/Chrome Companion", resources / "Chrome Companion")
    (resources / "runtime.json").write_text(json.dumps({
        "HARBOR_YTDLP_PATH": "Tools/yt-dlp",
        "HARBOR_FFMPEG_PATH": "Tools/ffmpeg",
        "HARBOR_DENO_PATH": "Tools/deno",
    }, indent=2) + "\n")


def sign_nested(identity):
    files = machos(APP)
    dependencies = {}
    for file in files:
        listing = run("otool", "-L", file, capture=True).stdout
        dependencies[str(file.relative_to(APP))] = listing
        references = "\n".join(line for line in listing.splitlines() if line.startswith("\t"))
        if any(forbidden in references for forbidden in ["/opt/homebrew/", "/usr/local/", "/Library/Frameworks/Python", "/Users/"]):
            raise SystemExit(f"Nonportable binary dependency: {file}")
    (REPORTS / "binary-dependencies.json").write_text(json.dumps(dependencies, indent=2) + "\n")

    def sign(file):
        # The main executable is sealed with its enclosing app after Resources
        # are final; verifying it earlier would inspect the old resource seal.
        if file == APP / "Contents/MacOS/MVD":
            return
        args = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp"]
        if file == APP / "Contents/Resources/Tools/deno":
            args += ["--entitlements", ROOT / "Packaging/deno-entitlements.plist"]
        run(*args, file, capture=True)
        run("codesign", "--verify", "--strict", file, capture=True)

    with ThreadPoolExecutor(max_workers=6) as workers:
        list(workers.map(sign, files))
    print(f"Signed and verified {len(files) - 1} nested Mach-O files.", flush=True)


def smoke():
    tools = APP / "Contents/Resources/Tools"
    environment = os.environ.copy()
    environment["PATH"] = "/usr/bin:/bin"
    environment["DENO_DIR"] = str(REPORTS / "deno-cache")
    environment["DENO_NO_UPDATE_CHECK"] = "1"
    environment.pop("PYTHONHOME", None)
    environment.pop("PYTHONPATH", None)
    checks = [
        [tools / "yt-dlp", "--ignore-config", "--no-plugin-dirs", "--version"],
        [tools / "Python/bin/python3.14", "-I", "-B", "-c", "import ssl, sqlite3, brotli, yt_dlp, yt_dlp_ejs; from Cryptodome.Cipher import AES; AES.new(b'0'*16,AES.MODE_ECB).encrypt(b'0'*16); print('Isolated Python and native modules passed')"],
        [tools / "deno", "eval", "const bytes=new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,7,7,1,3,114,117,110,0,0,10,6,1,4,0,65,42,11]); const m=new WebAssembly.Instance(new WebAssembly.Module(bytes)); if(m.exports.run()!==42)throw Error('Wasm result'); console.log('Hardened Deno WebAssembly execution passed')"],
        [tools / "ffmpeg", "-version"],
        [tools / "ffprobe", "-version"],
    ]
    results = []
    for command in checks:
        result = run(*command, capture=True, env=environment)
        results.append({"tool": str(command[0].relative_to(APP)), "output": result.stdout})
    (REPORTS / "tool-smoke.json").write_text(json.dumps(results, indent=2) + "\n")
    print("Signed provider, Python native modules, Deno JIT/Wasm and media tools passed.", flush=True)


def notarize(file, profile, label):
    print(f"Submitting {label} to Apple notarization…", flush=True)
    result = run("xcrun", "notarytool", "submit", file, "--keychain-profile", profile,
                 "--wait", "--output-format", "json", capture=True)
    report = json.loads(result.stdout)
    (REPORTS / f"{label}-notarization.json").write_text(json.dumps(report, indent=2) + "\n")
    if report.get("status") != "Accepted":
        submission = report.get("id")
        if submission:
            run("xcrun", "notarytool", "log", submission, "--keychain-profile", profile,
                REPORTS / f"{label}-notarization-log.json", capture=True)
        raise SystemExit(f"Apple did not accept {label}; inspect {REPORTS}.")
    print(f"Apple accepted {label}: {report['id']}", flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--notarize", action="store_true")
    parser.add_argument("--qualify-online", action="store_true")
    args = parser.parse_args()
    certificate, name = signing_identity()
    profile = os.environ.get("MVD_NOTARY_PROFILE")
    if args.notarize and not profile:
        raise SystemExit("Set MVD_NOTARY_PROFILE to a stored Keychain profile; no password belongs in this script.")
    REPORTS.mkdir(parents=True, exist_ok=True)
    DIST.mkdir(exist_ok=True)
    if not args.skip_build:
        environment = os.environ.copy()
        environment.update(MVD_BUILD_CONFIGURATION="release", MVD_BUILD_APP_DIR=str(APP))
        run(ROOT / "Scripts/build-app.sh", env=environment)
    assemble()
    sign_nested(certificate)
    smoke()
    run("codesign", "--force", "--sign", certificate, "--options", "runtime", "--timestamp", APP, capture=True)
    run("codesign", "--verify", "--deep", "--strict", APP)
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if args.qualify_online:
        run("python3", ROOT / "Tests/Integration/packaged_release.py", APP, "--online")
    if args.notarize:
        archive = REPORTS / f"MVD-{version}-notary.zip"
        archive.unlink(missing_ok=True)
        run("ditto", "-c", "-k", "--keepParent", APP, archive)
        notarize(archive, profile, "app")
        run("xcrun", "stapler", "staple", APP, capture=True)
        run("xcrun", "stapler", "validate", APP, capture=True)
        run("spctl", "--assess", "--type", "execute", "--verbose=2", APP, capture=True)

    staging = ROOT / "build/DMG Root"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    run("ditto", APP, staging / "MVD.app")
    (staging / "Applications").symlink_to("/Applications")
    run(ROOT / "Scripts/package-extension.sh")
    copy_tree(ROOT / "build/Chrome Companion", staging / "Chrome Companion")
    source_kit = ROOT / "Packaging/Runtime/output/MVD-media-sources-9.0.2-arm64.tar.gz"
    shutil.copy2(source_kit, staging / source_kit.name)
    (staging / "INSTALL.txt").write_text(
        "MVD — Mac Video Downloader\n\n"
        "Apple Silicon Mac · macOS 14 or newer\n\n"
        "1. Drag MVD.app to Applications and open it.\n"
        "2. In MVD, click Connect Chrome and follow its setup steps.\n"
        "   A separate Chrome Companion folder also includes an installation helper.\n\n"
        "All media tools are included. No Homebrew or Python installation is needed.\n"
        "This private extension uses Chrome's explicit Load unpacked installation.\n"
        "Third-party licenses are inside MVD.app/Contents/Resources/Licenses.\n"
        "The media-source archive contains exact sources and rebuild instructions.\n"
    )
    dmg = DIST / f"MVD-{version}-arm64.dmg"
    dmg.unlink(missing_ok=True)
    run("hdiutil", "create", "-volname", f"MVD {version}", "-srcfolder", staging,
        "-format", "UDZO", "-ov", dmg)
    run("codesign", "--force", "--sign", certificate, "--timestamp", dmg, capture=True)
    run("codesign", "--verify", "--strict", dmg)
    if args.notarize:
        notarize(dmg, profile, "dmg")
        run("xcrun", "stapler", "staple", dmg, capture=True)
        run("xcrun", "stapler", "validate", dmg, capture=True)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg, capture=True)
    extension = ROOT / f"build/Chrome Companion/MVD-Companion-{version}.zip"
    shutil.copy2(extension, DIST / extension.name)
    # A complete companion ZIP includes its explicit macOS installation helper;
    # the runtime-only ZIP is also useful when choosing Load unpacked manually.
    installer = DIST / f"MVD-Chrome-Installer-{version}.zip"
    installer.unlink(missing_ok=True)
    run("ditto", "-c", "-k", "--keepParent", ROOT / "build/Chrome Companion", installer)
    artifacts = [dmg, DIST / extension.name, installer]
    (DIST / "SHA256SUMS.txt").write_text("".join(f"{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}\n" for file in artifacts))
    (REPORTS / "release.json").write_text(json.dumps({
        "version": version, "build": info["CFBundleVersion"], "architecture": "arm64",
        "signer": name, "notarized": args.notarize,
        "artifacts": {file.name: file.stat().st_size for file in artifacts},
    }, indent=2) + "\n")
    print(f"Release ready: {dmg}", flush=True)


if __name__ == "__main__":
    main()
