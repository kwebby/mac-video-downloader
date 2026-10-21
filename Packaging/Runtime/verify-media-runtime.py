#!/usr/bin/env python3
"""Qualify the standalone media tools without touching MVD state or user files."""
import array
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import wave


runtime = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "output" / "arm64"
ffmpeg = runtime.resolve() / "bin" / "ffmpeg"
ffprobe = runtime.resolve() / "bin" / "ffprobe"


def run(arguments):
    return subprocess.run([str(item) for item in arguments], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)


for executable in (ffmpeg, ffprobe):
    dependencies = run(["/usr/bin/otool", "-L", executable]).stdout
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        assert dependency.startswith(("/usr/lib/", "/System/Library/")), (executable.name, dependency)

license_output = " ".join(run([ffmpeg, "-L"]).stdout.split())
assert "GNU Lesser General Public License" in license_output, license_output
protocols = run([ffmpeg, "-protocols"]).stdout
assert "https" in protocols and "tls" in protocols
version = run([ffmpeg, "-version"]).stdout
assert "--enable-securetransport" in version
assert "--disable-gpl" in version and "--disable-nonfree" in version

with tempfile.TemporaryDirectory(prefix="mvd-media-runtime-") as temporary:
    folder = Path(temporary)
    source = folder / "source.wav"
    samples = array.array("h", [int(9000 * math.sin(2 * math.pi * 440 * sample / 48000)) for sample in range(96000)])
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(source), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(48000)
        wav.writeframes(samples.tobytes())
    outputs = [("mp3", "libmp3lame", "mp3"), ("m4a", "aac", "aac"),
               ("opus", "libopus", "opus"), ("flac", "flac", "flac"),
               ("wav", "pcm_s16le", "pcm_s16le")]
    for extension, encoder, expected_codec in outputs:
        output = folder / f"converted.{extension}"
        command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", source,
                   "-map", "0:a:0", "-vn", "-c:a", encoder]
        if extension in ("mp3", "m4a", "opus"):
            command.extend(["-b:a", "128k"])
        run(command + [output])
        result = json.loads(run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", output]).stdout)
        assert len(result["streams"]) == 1, result
        assert result["streams"][0]["codec_type"] == "audio", result
        assert result["streams"][0]["codec_name"] == expected_codec, result
        assert 1.9 <= float(result["format"]["duration"]) <= 2.2, result
        print(f"PASS {extension}: {expected_codec}, audio-only, valid duration")
    # The app also preserves original codecs when assembling containers.
    remuxed = folder / "original-aac.mka"
    run([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", folder / "converted.m4a", "-c", "copy", remuxed])
    result = json.loads(run([ffprobe, "-v", "error", "-show_streams", "-of", "json", remuxed]).stdout)
    assert result["streams"][0]["codec_name"] == "aac", result
    print("PASS stream-copy/remux preserves AAC")

print("PASS LGPL configuration, all output encoders, HTTPS protocol, and system-only dynamic dependencies")
