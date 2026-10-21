#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${1:-$project_root/build}"
if [[ $# -gt 1 ]]; then
    echo 'Usage: Scripts/package-extension.sh [OUTPUT_DIRECTORY]' >&2
    exit 2
fi

# No Chrome profile, private key, native registration or installed app is changed.
# Python is a build-time dependency; the user-facing installer uses macOS tools.
python3 - "$project_root" "$output_root" <<'PY'
from pathlib import Path
import base64
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).expanduser().resolve()
source = root / 'BrowserExtension'
manifest = json.loads((source / 'manifest.json').read_text())
version = manifest['version']
if manifest.get('manifest_version') != 3 or not re.fullmatch(r'\d+(?:\.\d+){0,3}', version):
    raise SystemExit('Expected a Manifest V3 extension with a numeric Chrome version.')

public_key = ''.join((root / 'Packaging/Extension/public-key.b64').read_text().split())
public_der = base64.b64decode(public_key, validate=True)
subprocess.run(['/usr/bin/openssl', 'pkey', '-pubin', '-inform', 'DER', '-noout'],
               input=public_der, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
extension_id = ''.join(chr(ord('a') + int(char, 16)) for char in hashlib.sha256(public_der).hexdigest()[:32])
manifest['key'] = public_key

# Explicit runtime allowlist prevents test fixtures, docs, package metadata,
# source maps, hidden files and secrets from entering the browser package.
runtime_files = [
    'background.js', 'collector.js', 'core.js', 'overlay-ui.js',
    'panel-security.js', 'player-context.js', 'popup.js', 'registry.js',
    'popup.html', 'popup.css',
    'icons/icon-16.png', 'icons/icon-32.png', 'icons/icon-128.png',
]
allowed = set(runtime_files) | {'manifest.json'}
for path in source.iterdir():
    if path.is_file() and path.suffix in {'.js', '.html', '.css'} and path.name not in allowed:
        raise SystemExit(f'New runtime file {path.name} needs an explicit packaging review.')
for name in runtime_files:
    path = source / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f'Missing runtime file or unexpected symlink: {name}')

runtime_payloads = {name: (source / name).read_bytes() for name in runtime_files}
# Developer setup docs stay outside the installable runtime. Avoid leaving the
# source popup's README link pointing at a deliberately excluded file.
popup = runtime_payloads['popup.html'].decode('utf-8')
popup = re.sub(
    r'''<a\b[^>]*\bhref=["']README\.md["'][^>]*>.*?</a>''',
    '<span class="small muted">Setup: see INSTALL.txt included with this package.</span>',
    popup,
    flags=re.DOTALL,
)
runtime_payloads['popup.html'] = popup.encode('utf-8')

references = [manifest['background']['service_worker'], manifest['action']['default_popup']]
references += list(manifest.get('icons', {}).values())
references += list(manifest['action'].get('default_icon', {}).values())
for name in runtime_files:
    if name.endswith(('.js', '.html')):
        text = runtime_payloads[name].decode('utf-8')
        references += re.findall(r'''(?:from\s*|(?:src|href)\s*=\s*)["'](?:\./)?([^"']+)["']''', text)
for reference in references:
    if '://' not in reference and reference not in allowed:
        raise SystemExit(f'Runtime reference omitted from package: {reference}')

output.mkdir(parents=True, exist_ok=True)
release = output / 'Chrome Companion'
if release.is_symlink():
    raise SystemExit('Refusing to replace a symlink at the package output path.')
with tempfile.TemporaryDirectory(prefix='.mvd-extension-', dir=output) as temporary:
    stage = Path(temporary) / 'Chrome Companion'
    unpacked = stage / 'MVD Companion'
    unpacked.mkdir(parents=True)
    for name in runtime_files:
        target = unpacked / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(runtime_payloads[name])
        target.chmod(0o644)
    (unpacked / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    (unpacked / 'manifest.json').chmod(0o644)

    archive = stage / f'MVD-Companion-{version}.zip'
    # Fixed timestamps, ordering, permissions and no platform extra fields make
    # repeat packaging of identical inputs produce the same archive bytes.
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name in sorted(allowed):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(entry, (unpacked / name).read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

    for filename, original in [
        ('Install Chrome Companion.command', root / 'Scripts/install-chrome-companion.command'),
        ('install-chrome-host.sh', root / 'Scripts/install-chrome-host.sh'),
    ]:
        shutil.copyfile(original, stage / filename)
        (stage / filename).chmod(0o755)
    guide = (root / 'Packaging/Extension/INSTALL.txt').read_text()
    guide = guide.replace('@VERSION@', version).replace('@EXTENSION_ID@', extension_id)
    (stage / 'INSTALL.txt').write_text(guide)
    (stage / 'EXTENSION-ID.txt').write_text(extension_id + '\n')
    checked_files = sorted(path for path in stage.rglob('*') if path.is_file())
    checksums = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(stage).as_posix()}\n' for path in checked_files)
    (stage / 'SHA256SUMS.txt').write_text(checksums)
    if release.exists():
        shutil.rmtree(release)
    os.replace(stage, release)

print(f'Extension folder: {release / "MVD Companion"}')
print(f'Extension ZIP: {release / archive.name}')
print(f'Install guide: {release / "INSTALL.txt"}')
print(f'Packaged extension ID: {extension_id}')
print('Private unpacked build; no CRX, Chrome Web Store publication or machine registration performed.')
PY
