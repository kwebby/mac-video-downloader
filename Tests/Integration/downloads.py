#!/usr/bin/env python3
"""End-to-end broker tests using owned local bytes and generated media."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = bytes(range(256)) * 16384


class FixtureServer(http.server.BaseHTTPRequestHandler):
    media_directory = None
    range_lock = threading.Lock()
    range_active = 0
    range_peak = 0
    range_requests = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path.startswith('/range'):
            return self.serve_range()
        if self.path.startswith('/media/'):
            relative = self.path.split('?', 1)[0].removeprefix('/media/')
            target = self.media_directory / relative
            if '/' in relative or not target.is_file():
                self.send_error(404)
                return
            body = target.read_bytes()
            mime = 'application/vnd.apple.mpegurl' if target.suffix == '.m3u8' else 'video/mp4' if target.suffix == '.mp4' else 'video/mp2t'
        elif self.path == '/index.html':
            body = b'<html><a href="/file.bin">Owned fixture</a><video src="/media/test.mp4"></video></html>'
            mime = 'text/html'
        else:
            body, mime = PAYLOAD, 'application/octet-stream'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body) + (100 if self.path == '/truncated.bin' else 0)))
        self.send_header('ETag', '"owned-fixture-v1"')
        self.end_headers()
        try:
            for index in range(0, len(body), 16384):
                self.wfile.write(body[index:index + 16384])
                self.wfile.flush()
                if self.path.startswith('/slow'):
                    time.sleep(.01)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def serve_range(self):
        range_value = self.headers.get('Range')
        if_range = self.headers.get('If-Range')
        with self.range_lock:
            type(self).range_requests.append((self.path, range_value, if_range))
        is_probe = range_value == 'bytes=0-0'
        body = PAYLOAD
        etag = 'W/"fixture-v1"' if self.path == '/range-weak.bin' else '"fixture-v1"'
        if self.path == '/range-malformed.bin':
            etag = '"bad"tag"'
        if self.path == '/range-change.bin' and not is_probe:
            body = bytes(reversed(PAYLOAD))
            etag = '"fixture-v2"'
        start, end = 0, len(body) - 1
        honored = range_value is not None and not (self.path == '/range-ignore.bin' and not is_probe)
        if honored:
            start, end = map(int, range_value.removeprefix('bytes=').split('-'))
            if not (0 <= start <= end < len(body)):
                self.send_error(416)
                return
        self.send_response(206 if honored else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('ETag', etag)
        self.send_header('Content-Length', str(end - start + 1))
        if honored:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
        self.end_headers()
        with self.range_lock:
            type(self).range_active += 1
            type(self).range_peak = max(type(self).range_peak, type(self).range_active)
        try:
            for offset in range(start, end + 1, 16384):
                self.wfile.write(body[offset:min(end + 1, offset + 16384)])
                self.wfile.flush()
                if not is_probe:
                    time.sleep(.002)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with self.range_lock:
                type(self).range_active -= 1
        self.close_connection = True


class BrokerIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = Path(tempfile.mkdtemp(prefix='harbor-test-', dir='/tmp'))
        cls.support = cls.temp / 'state'
        cls.output = cls.temp / 'downloads'
        cls.media = cls.temp / 'media'
        cls.media.mkdir()
        cls.environment = os.environ.copy()
        cls.environment['HARBOR_SUPPORT_DIR'] = str(cls.support)
        cls.environment['HARBOR_YTDLP_PATH'] = str(ROOT / '.tools/python/bin/yt-dlp')
        for key, name in [('HARBOR_FFMPEG_PATH', 'ffmpeg'), ('HARBOR_DENO_PATH', 'deno')]:
            if path := shutil.which(name):
                cls.environment[key] = path
        binary_dir = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()
        cls.broker_binary = Path(binary_dir) / 'HarborBroker'
        cls.log = (cls.temp / 'broker.log').open('wb')
        cls.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureServer)
        FixtureServer.media_directory = cls.media
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.base = f'http://127.0.0.1:{cls.httpd.server_port}'
        if ffmpeg := shutil.which('ffmpeg'):
            subprocess.run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=160x90:rate=12',
                            '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '2', '-c:v', 'libx264',
                            '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', str(cls.media / 'test.mp4')], check=True)
            subprocess.run([ffmpeg, '-v', 'error', '-i', str(cls.media / 'test.mp4'), '-c', 'copy',
                            '-hls_time', '1', '-hls_list_size', '0', str(cls.media / 'test.m3u8')], check=True)
            (cls.media / 'master.m3u8').write_text('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=150000,RESOLUTION=160x90\ntest.m3u8\n')
        cls.start_broker()
        result = cls.request('setSettings', settings={'destinationDirectory': str(cls.output), 'maxConcurrent': 2})
        if result.get('error'):
            raise RuntimeError(result['error'])

    @classmethod
    def start_broker(cls):
        cls.process = subprocess.Popen([str(cls.broker_binary)], env=cls.environment, stdout=cls.log, stderr=cls.log)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                cls.request('hello')
                return
            except (OSError, EOFError):
                if cls.process.poll() is not None:
                    raise RuntimeError((cls.temp / 'broker.log').read_text())
                time.sleep(.1)
        raise RuntimeError('Broker did not become ready')

    @classmethod
    def stop_broker(cls):
        try:
            cls.request('shutdown')
            cls.process.wait(timeout=10)
        except (OSError, EOFError, subprocess.TimeoutExpired):
            cls.process.kill()
            cls.process.wait()

    @classmethod
    def tearDownClass(cls):
        cls.stop_broker()
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.log.close()
        if os.environ.get('HARBOR_KEEP_TEST_FILES'):
            print(f'Test files retained: {cls.temp}')
        else:
            shutil.rmtree(cls.temp)

    @classmethod
    def request(cls, command, **values):
        payload = json.dumps({'protocolVersion': 1, 'requestID': str(uuid.uuid4()), 'command': command, **values}).encode()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
            channel.settimeout(40)
            channel.connect(str(cls.support / 'broker.sock'))
            channel.sendall(struct.pack('<I', len(payload)) + payload)

            def receive(length):
                result = b''
                while len(result) < length:
                    block = channel.recv(length - len(result))
                    if not block:
                        raise EOFError('Service disconnected')
                    result += block
                return result

            size, = struct.unpack('<I', receive(4))
            if size > 4 * 1024 * 1024:
                raise ValueError('Oversized response')
            return json.loads(receive(size))

    def enqueue(self, path, kind='direct', key=None):
        response = self.request('enqueue', url=self.base + path, kind=kind, idempotencyKey=key or str(uuid.uuid4()))
        self.assertFalse(response.get('error'), response)
        self.assertTrue(response.get('jobID'), response)
        return response['jobID']

    def job(self, job_id):
        return next(job for job in self.request('list')['jobs'] if job['id'] == job_id)

    def wait_for(self, job_id, states=('completed',), timeout=40):
        deadline = time.monotonic() + timeout
        job = None
        while time.monotonic() < deadline:
            job = self.job(job_id)
            if job['status'] in states:
                return job
            if job['status'] == 'failed' and 'failed' not in states:
                self.fail(f'Download failed: {job.get("errorMessage")}')
            time.sleep(.1)
        self.fail(f'Timed out: {job}')

    def test_01_durable_idempotency_exact_bytes_and_collision(self):
        key = str(uuid.uuid4())
        job_id = self.enqueue('/file.bin', key=key)
        self.assertEqual(self.enqueue('/file.bin', key=key), job_id)
        first = self.wait_for(job_id)
        first_path = Path(first['outputPath'])
        self.assertEqual(hashlib.sha256(first_path.read_bytes()).digest(), hashlib.sha256(PAYLOAD).digest())
        second = self.wait_for(self.enqueue('/file.bin'))
        self.assertNotEqual(first['outputPath'], second['outputPath'])
        self.assertEqual(first_path.read_bytes(), PAYLOAD)
        self.assertEqual(Path(second['outputPath']).read_bytes(), PAYLOAD)

    def test_02_pause_and_safe_restart(self):
        job_id = self.enqueue('/slow.bin')
        self.wait_for(job_id, states=('downloading',))
        time.sleep(.2)
        response = self.request('pause', jobID=job_id)
        self.assertFalse(response.get('error'), response)
        self.wait_for(job_id, states=('paused',))
        self.request('resume', jobID=job_id)
        completed = self.wait_for(job_id)
        self.assertEqual(Path(completed['outputPath']).read_bytes(), PAYLOAD)

    def test_03_truncated_response_never_published(self):
        job_id = self.enqueue('/truncated.bin')
        failed = self.wait_for(job_id, states=('failed',))
        self.assertIsNone(failed.get('outputPath'))
        self.assertTrue(failed.get('errorMessage'))

    def test_04_invalid_input_rejected(self):
        self.assertTrue(self.request('enqueue', url='file:///etc/hosts').get('error'))
        self.assertTrue(self.request('enqueue', url='https://user:secret@example.com/video').get('error'))
        self.assertTrue(self.request('setSettings', settings={'destinationDirectory': str(self.output), 'maxConcurrent': 99}).get('error'))

    def test_05_jobs_survive_service_restart(self):
        job_id = self.enqueue('/slow-restart.bin')
        self.wait_for(job_id, states=('downloading',))
        self.request('pause', jobID=job_id)
        self.wait_for(job_id, states=('paused',))
        self.stop_broker()
        self.start_broker()
        self.assertEqual(self.job(job_id)['status'], 'paused')
        self.request('resume', jobID=job_id)
        self.assertEqual(Path(self.wait_for(job_id)['outputPath']).read_bytes(), PAYLOAD)

    def test_06_real_media_worker(self):
        if not (self.media / 'test.mp4').is_file() or not Path(self.environment['HARBOR_YTDLP_PATH']).is_file():
            self.skipTest('Media developer tools unavailable')
        for path in ['/media/test.mp4', '/media/test.m3u8']:
            with self.subTest(path=path):
                job = self.wait_for(self.enqueue(path, kind='media'))
                output = Path(job['outputPath'])
                probe = subprocess.check_output([shutil.which('ffprobe'), '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', str(output)], text=True)
                self.assertGreater(float(json.loads(probe)['format']['duration']), 1.5)

    def test_07_preview_and_selected_quality(self):
        if not (self.media / 'master.m3u8').is_file():
            self.skipTest('FFmpeg fixture unavailable')
        response = self.request('resolveMedia', url=self.base + '/media/master.m3u8')
        self.assertFalse(response.get('error'), response)
        preview = response['mediaPreview']
        self.assertFalse(preview['isDirectFile'])
        self.assertIn(90, [quality.get('height') for quality in preview['qualities']])
        quality = next(quality for quality in preview['qualities'] if quality.get('height') == 90)
        accepted = self.request('enqueue', url=self.base + '/media/master.m3u8', kind='media', quality=quality, idempotencyKey=str(uuid.uuid4()))
        self.assertFalse(accepted.get('error'), accepted)
        job = self.wait_for(accepted['jobID'])
        self.assertEqual(job['quality']['height'], 90)
        probe = json.loads(subprocess.check_output([shutil.which('ffprobe'), '-v', 'error', '-show_entries', 'stream=height', '-of', 'json', job['outputPath']], text=True))
        self.assertIn(90, [stream.get('height') for stream in probe['streams']])
        self.assertTrue(self.request('enqueue', url=self.base + '/media/master.m3u8', kind='media', quality={'id': '--exec', 'label': 'bad', 'height': 90}).get('error'))
        direct = self.request('resolveMedia', url=self.base + '/media/test.mp4')
        self.assertTrue(direct['mediaPreview']['isDirectFile'])

    def test_08_bulk_queue_budget(self):
        ids = [self.enqueue(f'/slow-batch-{index}.bin') for index in range(5)]
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            jobs = [job for job in self.request('list')['jobs'] if job['id'] in ids]
            active = [job for job in jobs if job['status'] in ('downloading', 'resolving', 'processing')]
            self.assertLessEqual(len(active), 2)
            self.assertFalse([job for job in jobs if job['status'] == 'failed'], jobs)
            if len([job for job in jobs if job['status'] == 'completed']) == 5:
                return
            time.sleep(.1)
        self.fail('Bulk queue did not complete')

    def test_09_bounded_history_pages_and_small_acknowledgments(self):
        self.stop_broker()
        fixture_ids = set()
        with sqlite3.connect(self.support / 'downloads.sqlite3') as database:
            for index in range(120):
                job_id = str(uuid.uuid4()).upper()
                fixture_ids.add(job_id)
                job = {'id': job_id, 'sourceURL': 'https://example.com/' + '/' * 14000 + str(index),
                       'title': 'Large history fixture', 'filename': 'fixture.bin',
                       'destinationDirectory': str(self.output), 'status': 'paused', 'kind': 'direct',
                       'bytesReceived': 0, 'bytesPerSecond': 0, 'createdAt': index,
                       'idempotencyKey': str(uuid.uuid4())}
                database.execute('INSERT INTO jobs(id,idempotency_key,data) VALUES(?,?,?)',
                                 (job_id, job['idempotencyKey'], json.dumps(job).encode()))
        self.start_broker()
        hello = self.request('hello')
        self.assertLess(len(json.dumps(hello)), 65536)
        offset = 0
        found = set()
        while True:
            response = self.request('list', pageOffset=offset)
            self.assertFalse(response.get('error'), response)
            self.assertLess(len(json.dumps(response).encode()), 2 * 1024 * 1024)
            self.assertLessEqual(len(response['jobs']), 50)
            found.update(job['id'] for job in response['jobs'])
            next_offset = response.get('nextPageOffset')
            if next_offset is None:
                break
            self.assertGreater(next_offset, offset)
            offset = next_offset
        self.assertTrue(fixture_ids.issubset(found))
        acknowledgment = self.request('pause', jobID=next(iter(fixture_ids)))
        self.assertFalse(acknowledgment.get('error'), acknowledgment)
        self.assertEqual(acknowledgment.get('jobs'), [])

    def test_10_audio_only_and_video_only(self):
        if not (self.media / 'test.mp4').is_file():
            self.skipTest('FFmpeg fixture unavailable')
        for mode, audio_format, bitrate in [('audioOnly', 'mp3', 192), ('videoOnly', 'original', None)]:
            with self.subTest(mode=mode):
                options = {'mode': mode, 'container': 'auto', 'audioFormat': audio_format, 'accelerated': False}
                if bitrate:
                    options['audioBitrateKbps'] = bitrate
                response = self.request('enqueue', url=self.base + '/media/test.mp4', kind='automatic',
                                        options=options, idempotencyKey=str(uuid.uuid4()))
                self.assertFalse(response.get('error'), response)
                job = self.wait_for(response['jobID'])
                probe = json.loads(subprocess.check_output([shutil.which('ffprobe'), '-v', 'error', '-show_entries',
                                    'stream=codec_type,codec_name,bit_rate', '-of', 'json', job['outputPath']], text=True))
                types = [stream['codec_type'] for stream in probe['streams']]
                self.assertEqual(types, ['audio'] if mode == 'audioOnly' else ['video'])
                if mode == 'audioOnly':
                    self.assertEqual(probe['streams'][0]['codec_name'], 'mp3')
                    self.assertAlmostEqual(int(probe['streams'][0]['bit_rate']), 192000, delta=5000)

    def test_11_folder_shortcuts_and_per_job_destination(self):
        folder_id = str(uuid.uuid4()).upper()
        path = self.temp / 'learning'
        folder = {'id': folder_id, 'name': 'Learning', 'path': str(path), 'icon': 'book', 'colorHex': '16874B'}
        saved = self.request('saveFolder', folder=folder)
        self.assertFalse(saved.get('error'), saved)
        self.assertTrue(any(item['id'] == folder_id for item in saved['folders']))
        response = self.request('enqueue', url=self.base + '/file.bin', kind='direct', folderID=folder_id, idempotencyKey=str(uuid.uuid4()))
        self.assertFalse(response.get('error'), response)
        completed = self.wait_for(response['jobID'])
        self.assertEqual(Path(completed['outputPath']).parent, path)
        self.assertEqual(Path(completed['outputPath']).read_bytes(), PAYLOAD)
        folder['name'], folder['icon'] = 'Tutorials', 'folder'
        updated = self.request('saveFolder', folder=folder)
        self.assertFalse(updated.get('error'), updated)
        self.assertEqual(next(item for item in updated['folders'] if item['id'] == folder_id)['name'], 'Tutorials')
        removed = self.request('removeFolder', folderID=folder_id)
        self.assertFalse(removed.get('error'), removed)
        self.assertTrue(Path(completed['outputPath']).is_file())
        self.assertEqual(self.job(response['jobID']).get('folderID'), None)

    def test_12_real_segmented_acceleration_and_safe_fallback(self):
        options = {'mode': 'videoWithAudio', 'container': 'auto', 'audioFormat': 'original', 'accelerated': True}
        for path, expected in [('/range.bin', PAYLOAD), ('/range-ignore.bin', PAYLOAD),
                               ('/range-change.bin', bytes(reversed(PAYLOAD))), ('/range-weak.bin', PAYLOAD),
                               ('/range-malformed.bin', PAYLOAD)]:
            with self.subTest(path=path):
                with FixtureServer.range_lock:
                    FixtureServer.range_peak = 0
                    FixtureServer.range_requests = []
                response = self.request('enqueue', url=self.base + path, kind='direct', options=options, idempotencyKey=str(uuid.uuid4()))
                self.assertFalse(response.get('error'), response)
                completed = self.wait_for(response['jobID'])
                self.assertEqual(Path(completed['outputPath']).read_bytes(), expected)
                with FixtureServer.range_lock:
                    requests = list(FixtureServer.range_requests)
                    peak = FixtureServer.range_peak
                if path == '/range.bin':
                    ranges = [request for request in requests if request[2] is not None]
                    self.assertGreaterEqual(len(ranges), 2)
                    self.assertGreaterEqual(peak, 2)
                    print(f'Range acceleration verified: {len(ranges)} validated parts; {peak} overlapping server requests')
                else:
                    self.assertTrue(any(request[1] is None for request in requests), requests)

    def test_13_paused_job_options_can_change_without_mixing_data(self):
        job_id = self.enqueue('/slow-options.bin')
        self.wait_for(job_id, states=('downloading',))
        self.request('pause', jobID=job_id)
        self.wait_for(job_id, states=('paused',))
        destination = self.temp / 'custom-location'
        deadline = time.monotonic() + 5
        while True:
            changed = self.request('updateOptions', jobID=job_id,
                                   destinationDirectory=str(destination),
                                   options={'mode': 'videoWithAudio', 'container': 'auto', 'audioFormat': 'original', 'accelerated': True})
            if not changed.get('error') or time.monotonic() > deadline:
                break
            time.sleep(.1)
        self.assertFalse(changed.get('error'), changed)
        self.request('resume', jobID=job_id)
        completed = self.wait_for(job_id)
        self.assertEqual(Path(completed['outputPath']).parent, destination)
        self.assertEqual(Path(completed['outputPath']).read_bytes(), PAYLOAD)


if __name__ == '__main__':
    unittest.main(verbosity=2)
