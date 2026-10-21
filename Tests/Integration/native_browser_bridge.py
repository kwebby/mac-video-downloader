#!/usr/bin/env python3
"""Opt-in online qualification of the registered, packaged native browser bridge.

Defaults to a public 19-second sample; --url selects another public provider.
Uses isolated broker state/output, never the user's queue or files. The extension
must already be registered for this app.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('extension_id', help='Exact registered Chrome extension ID')
    parser.add_argument('--url', default='https://www.youtube.com/watch?v=jNQXAC9IVRw',
                        help='Public video URL for this opt-in provider qualification')
    parser.add_argument('--exact-format', action='store_true',
                        help='Exercise an actual preview-returned source format with audio')
    args = parser.parse_args()
    if not re.fullmatch('[a-p]{32}', args.extension_id):
        parser.error('Use the exact 32-character Chrome extension ID.')
    bundle = ROOT / 'build/MVD.app/Contents/MacOS'
    cli = bundle / 'harborctl'
    host = bundle / 'HarborNativeHost'
    with tempfile.TemporaryDirectory(prefix='mvd-native-bridge-') as temporary:
        root = Path(temporary)
        environment = os.environ.copy()
        environment['HARBOR_SUPPORT_DIR'] = str(root / 'state')
        source = args.url

        def control(*arguments):
            return json.loads(subprocess.check_output([str(cli), *arguments], env=environment, timeout=40))

        def native(command, **fields):
            request_id = str(uuid.uuid4())
            request = dict(protocolVersion=1, requestID=request_id, command=command, **fields)
            payload = json.dumps(request).encode()
            process = subprocess.run([str(host), f'chrome-extension://{args.extension_id}/'],
                                     input=struct.pack('<I', len(payload)) + payload,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=environment, timeout=45)
            if process.returncode != 0 or len(process.stdout) < 4:
                raise AssertionError('The registered native host did not return a framed response.')
            length = struct.unpack('<I', process.stdout[:4])[0]
            assert len(process.stdout) == length + 4 and length <= 256 * 1024
            response = json.loads(process.stdout[4:])
            assert response['requestID'] == request_id or (response.get('error') and response['requestID'] == ''), response
            return response

        try:
            control('settings', '--destination', str(root / 'downloads'))
            hello = native('hello')
            assert not hello.get('error') and hello.get('mediaPanelAvailable') is True, hello
            folders = native('listFolders')
            assert not folders.get('error') and 'defaultFolderName' in folders, folders
            assert str(root) not in json.dumps(folders), 'Browser folder response leaked an absolute path.'
            rejected = native('resolveMedia', url=source, sourcePageURL=source, userGesture=False)
            assert rejected.get('error'), 'Resolution without a user action was accepted.'
            preview = native('resolveMedia', url=source, sourcePageURL=source, userGesture=True)
            assert not preview.get('error'), preview
            metadata = preview['mediaPreview']
            assert metadata['title'] and metadata['qualities'] and metadata['formats'], metadata
            key = str(uuid.uuid4())
            options = dict(mode='audioOnly', audioFormat='mp3', audioBitrateKbps=128)
            if args.exact_format:
                choices = [item for item in metadata['formats'] if item.get('hasAudio')]
                assert choices, 'The preview returned no source with audio.'
                selected = max(choices, key=lambda item: item.get('height') or 0)
                options['formatID'] = selected['id']
                print('Qualifying exact source format:', selected['label'])
            fields = dict(url=source, sourcePageURL=source, userGesture=True, idempotencyKey=key,
                          options=options)
            accepted = native('enqueueMedia', **fields)
            assert not accepted.get('error') and accepted.get('jobID'), accepted
            duplicate = native('enqueueMedia', **fields)
            assert duplicate.get('jobID') == accepted['jobID'], duplicate
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                jobs = control('list')['jobs']
                job = next(job for job in jobs if job['id'] == accepted['jobID'])
                if job['status'] == 'completed':
                    output = Path(job['outputPath'])
                    assert output.is_relative_to(root) and output.is_file()
                    probe = json.loads(subprocess.check_output([
                        shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe', '-v', 'error',
                        '-show_entries', 'stream=codec_type,codec_name', '-of', 'json', str(output)]))
                    assert [stream['codec_type'] for stream in probe['streams']] == ['audio'], probe
                    assert probe['streams'][0]['codec_name'] == 'mp3', probe
                    print('Registered native bridge passed: real provider preview, named default folder,')
                    print('gesture rejection, durable idempotency, and audio-only MP3 output in isolated state.')
                    return
                assert job['status'] not in ('failed', 'cancelled'), job.get('errorMessage', job['status'])
                time.sleep(.3)
            raise AssertionError('The isolated browser download did not finish within 90 seconds.')
        finally:
            try:
                subprocess.run([str(cli), 'shutdown'], env=environment, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass


if __name__ == '__main__':
    main()
