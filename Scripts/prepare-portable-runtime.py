#!/usr/bin/env python3
"""Assemble pinned arm64 tools without build-Mac interpreter/library paths."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "Packaging/Runtime"
OUTPUT = ROOT / "build/PortableRuntime"
TOOLS = OUTPUT / "Tools"
LOCK = json.loads((CACHE / "portable-tools.lock.json").read_text())


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def verified_archive(component, filename):
    info = LOCK[component]
    target = CACHE / filename
    if not target.exists():
        run("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--output", target, info["url"])
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if info["digest"] != "sha256:" + digest:
        raise SystemExit(f"{component} archive digest mismatch")
    return target


def prepare_wheels(interpreter, wheelhouse, wheel_lock, requirements):
    """Fetch missing pinned wheels without changing the reviewed hash lock."""
    if not wheel_lock.is_file():
        raise SystemExit("Missing Python wheel lock; add reviewed SHA-256 pins before building a release.")
    hashes = json.loads(wheel_lock.read_text())
    if not isinstance(hashes, dict) or not hashes:
        raise SystemExit("Python wheel lock must contain filename/SHA-256 entries.")
    normalize = lambda name: re.sub(r"[-_.]+", "-", name).lower()
    declared = {}
    for raw in requirements.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9_.-]*)==([^\s;#]+)", line)
        if not match or normalize(match[1]) in declared:
            raise SystemExit("Media requirements must contain unique exact package/version pins.")
        declared[normalize(match[1])] = match[2]
    locked = {}
    for name, digest in hashes.items():
        if not isinstance(name, str) or Path(name).name != name or not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise SystemExit("Invalid Python wheel filename or SHA-256 pin.")
        parts = name.split("-")
        if len(parts) < 5 or not name.endswith(".whl") or not re.fullmatch(r"[A-Za-z0-9_.]+", parts[0]) or not re.fullmatch(r"[A-Za-z0-9_.!+]+", parts[1]):
            raise SystemExit("Invalid locked Python wheel name.")
        key = normalize(parts[0])
        if key in locked:
            raise SystemExit("Python wheel lock must select one wheel per package for this runtime.")
        locked[key] = (name, digest, parts[1])
    if {key: entry[2] for key, entry in locked.items()} != declared:
        raise SystemExit("Python wheel lock and media requirements disagree; review both pins together.")
    wheelhouse.mkdir(parents=True, exist_ok=True)
    missing = []
    for name, digest, version in locked.values():
        file = wheelhouse / name
        if file.exists():
            if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
                raise SystemExit(f"Pinned Python wheel changed: {name}")
        else:
            missing.append((name, digest, version))
    if missing:
        with tempfile.TemporaryDirectory(prefix="mvd-wheels-", dir=wheelhouse.parent) as directory:
            stage = Path(directory)
            downloads = stage / "downloads"
            downloads.mkdir()
            pins = stage / "requirements.txt"
            pins.write_text("".join(f"{name.split('-')[0]}=={version} --hash=sha256:{digest}\n" for name, digest, version in missing))
            run(interpreter, "-I", "-B", "-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:",
                "--no-deps", "--require-hashes", "--dest", downloads, "--requirement", pins)
            if {file.name for file in downloads.iterdir()} != {name for name, _, _ in missing}:
                raise SystemExit("Downloaded wheel filenames differ from the reviewed lock.")
            for name, digest, _ in missing:
                file = downloads / name
                if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
                    raise SystemExit(f"Downloaded Python wheel digest mismatch: {name}")
            for name, _, _ in missing:
                os.replace(downloads / name, wheelhouse / name)
    files = [wheelhouse / name for name in sorted(hashes)]
    if any(hashlib.sha256(file.read_bytes()).hexdigest() != hashes[file.name] for file in files):
        raise SystemExit("Pinned Python wheel changed during preparation.")
    return files


def main():
    if os.uname().machine != "arm64":
        raise SystemExit("This pinned release runtime targets Apple Silicon (arm64).")
    python_archive = verified_archive("python", "python-portable.tar.gz")
    deno_archive = verified_archive("deno", "deno-portable.zip")
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    TOOLS.mkdir(parents=True)
    with tarfile.open(python_archive) as archive:
        archive.extractall(TOOLS, filter="data")
    (TOOLS / "python").rename(TOOLS / "Python")
    interpreter = TOOLS / "Python/bin/python3.14"
    wheelhouse = CACHE / "wheels"
    wheel_lock = CACHE / "python-wheels.lock.json"
    wheels = prepare_wheels(interpreter, wheelhouse, wheel_lock, ROOT / "Scripts/media-requirements.txt")
    run(interpreter, "-I", "-B", "-m", "pip", "install", "--disable-pip-version-check", "--no-index", "--no-deps", "--no-compile", *wheels)
    # Install-only Python includes pip for this build step. It is unnecessary in
    # the sealed app; removing it also removes a runtime package-install path.
    site = TOOLS / "Python/lib/python3.14/site-packages"
    for file in site.glob("pip*"):
        if file.is_dir():
            shutil.rmtree(file)
    for file in (TOOLS / "Python/bin").iterdir():
        if file.name not in {"python3.14", "python3", "python"}:
            if file.is_dir():
                shutil.rmtree(file)
            else:
                file.unlink()
    for file in (TOOLS / "Python").rglob("__pycache__"):
        shutil.rmtree(file)
    # Header/static archives and test suites are not needed by this interpreter.
    for relative in ["include", "lib/python3.14/test", "lib/python3.14/idlelib", "lib/python3.14/tkinter", "lib/tcl8.6", "lib/tk8.6"]:
        file = TOOLS / "Python" / relative
        if file.is_dir():
            shutil.rmtree(file)
    for file in (TOOLS / "Python").rglob("*.a"):
        file.unlink()
    with zipfile.ZipFile(deno_archive) as archive:
        data = archive.read("deno")
    (TOOLS / "deno").write_bytes(data)
    (TOOLS / "deno").chmod(0o755)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    run("xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=14.0", "-isysroot", sdk, "-O2", ROOT / "Packaging/yt-dlp-launcher.c", "-o", TOOLS / "yt-dlp")
    notices = OUTPUT / "Licenses"
    notices.mkdir()
    shutil.copy2(TOOLS / "Python/lib/python3.14/LICENSE.txt", notices / "Python-LICENSE.txt")
    for metadata in site.glob("*.dist-info"):
        for relative in ["licenses", "LICENSE", "LICENSE.txt", "COPYING", "COPYING.txt"]:
            file = metadata / relative
            if file.is_dir():
                shutil.copytree(file, notices / metadata.name / relative, dirs_exist_ok=True)
            elif file.is_file():
                dest = notices / metadata.name / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(file, dest)
    shutil.copy2(CACHE / "deno-LICENSE.md", notices / "Deno-LICENSE.md")
    for file in [CACHE / "portable-tools.lock.json", wheel_lock, ROOT / "Scripts/media-requirements.txt"]:
        shutil.copy2(file, notices / file.name)
    run(TOOLS / "yt-dlp", "--version")
    run(TOOLS / "deno", "--version")
    print(f"Portable Python/provider runtime ready: {OUTPUT}")


if __name__ == "__main__":
    main()
