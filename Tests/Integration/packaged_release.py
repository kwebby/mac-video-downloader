#!/usr/bin/env python3
"""Qualify a moved app with system-only PATH and isolated broker state.

--online additionally resolves a public sample and produces a verified MP3.
No installed app, Chrome registration, user queue, or user downloads are changed.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--online", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mvd-rel-", dir="/tmp") as temporary:
        root = Path(temporary)
        app = root / "Moved folder/MVD.app"
        shutil.copytree(args.app.resolve(), app, symlinks=True)
        cli = app / "Contents/MacOS/harborctl"
        probe = app / "Contents/Resources/Tools/ffprobe"
        state = root / "state"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("HARBOR_")}
        environment.update(PATH="/usr/bin:/bin", HARBOR_SUPPORT_DIR=str(state),
                           DENO_DIR=str(root / "deno-cache"), DENO_NO_UPDATE_CHECK="1")
        environment.pop("PYTHONHOME", None)
        environment.pop("PYTHONPATH", None)

        def control(*arguments):
            result = subprocess.run([str(cli), *arguments], env=environment,
                                    capture_output=True, text=True, timeout=45, check=True)
            return json.loads(result.stdout)

        def request(command, **fields):
            payload = json.dumps(dict(protocolVersion=1, requestID=str(uuid.uuid4()), command=command, **fields)).encode()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(40)
                connection.connect(str(state / "broker.sock"))
                connection.sendall(struct.pack("<I", len(payload)) + payload)

                def exactly(count):
                    data = bytearray()
                    while len(data) < count:
                        part = connection.recv(count - len(data))
                        if not part:
                            raise AssertionError("Incomplete broker frame")
                        data.extend(part)
                    return data

                size = struct.unpack("<I", exactly(4))[0]
                assert 0 < size <= 4 * 1024 * 1024
                result = json.loads(exactly(size))
                assert not result.get("error"), result.get("error")
                return result

        try:
            hello = control("hello")
            capabilities = {entry["id"]: entry for entry in hello["capabilities"]}
            for name in ["yt-dlp", "ffmpeg", "deno"]:
                assert capabilities[name]["available"], capabilities[name]
                assert str(app / "Contents/Resources/Tools") in capabilities[name]["detail"], capabilities[name]
            print("Moved app discovered all bundled tools with system-only PATH.", flush=True)
            if args.online:
                control("settings", "--destination", str(root / "downloads"))
                source = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
                preview = control("resolve", source)["mediaPreview"]
                assert preview["title"] and preview["formats"] and preview["qualities"]
                accepted = request("enqueue", url=source, kind="media", idempotencyKey=str(uuid.uuid4()),
                                   options=dict(mode="audioOnly", audioFormat="mp3", audioBitrateKbps=128))
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    job = next(job for job in control("list")["jobs"] if job["id"] == accepted["jobID"])
                    assert job["status"] not in ["failed", "cancelled"], job.get("errorMessage", job["status"])
                    if job["status"] == "completed":
                        output = Path(job["outputPath"])
                        assert output.is_relative_to(root) and output.stat().st_size > 10_000
                        metadata = json.loads(subprocess.check_output([str(probe), "-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "json", str(output)], env=environment))
                        assert len(metadata["streams"]) == 1 and metadata["streams"][0]["codec_name"] == "mp3", metadata
                        print("Moved portable app resolved YouTube and completed a verified audio-only MP3.", flush=True)
                        break
                    time.sleep(0.3)
                else:
                    raise AssertionError("Portable provider download timed out")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            print("Bundle signature remained valid after provider execution.", flush=True)
        finally:
            try:
                control("shutdown")
            except (OSError, subprocess.SubprocessError, ValueError):
                pass


if __name__ == "__main__":
    main()
