# Portable media runtime

`output/arm64/bin/ffmpeg` and `ffprobe` are standalone Apple Silicon tools for macOS 13 or later. The app can bundle them without requiring Homebrew, Python or any external media-library installation on the user's Mac.

The build pins FFmpeg 9.0.2, LAME 4.0 and Opus 1.6.1 in `media-sources.lock`. FFmpeg is configured as LGPL 2.1 or later with GPL, nonfree and version3 disabled. Its libraries and the selected LAME/Opus libraries are statically linked into the two command-line executables. Dynamic dependencies resolve only to macOS system libraries/frameworks. TLS uses system SecureTransport. See `MEDIA-NOTICES.md` and the exact license texts in `output/arm64/licenses`.

## Build and qualify

On a macOS build machine with Apple Command Line Tools and `pkg-config`:

```sh
bash Packaging/Runtime/build-media-runtime.sh arm64
python3 Packaging/Runtime/verify-media-runtime.py
```

`pkg-config` only reads the private prefix's metadata at build time. `--disable-autodetect` prevents linking incidental Homebrew libraries. No files are installed globally. `MVD_BUILD_JOBS` defaults to six and `MVD_MACOS_DEPLOYMENT_TARGET` defaults to 13.0. SHA-256 mismatches stop the build.

Qualification generates an isolated PCM fixture, encodes each current MVD audio output (MP3, M4A/AAC, Opus, FLAC and WAV), checks the resulting codec/stream/duration through FFprobe, and verifies original-AAC stream-copy/remux. It checks LGPL configuration, HTTPS protocol support and every dynamic dependency. The initial native arm64 build passed these checks. An additional live HTTPS probe of `https://www.w3schools.com/html/mov_bbb.mp4` succeeded with H.264/AAC streams; its output is in `reports/https-mp4-probe.json`. SecureTransport still has server-specific TLS compatibility limits, so this is not a universal HTTPS or website-support claim. Live-site download qualification is performed separately by MVD's integration tests.

## Distribute

Copy only `output/arm64/bin` into the app's runtime location. Include the corresponding `licenses`, `source` and `reports` materials with the distribution, for example as `MVD-media-sources-9.0.2-arm64.tar.gz` beside the app in the DMG. The source archive contains exact unmodified upstream source archives, checksum lock, build instructions and configuration reports. A recipient can unpack it, open `source`, and run `bash build-media-runtime.sh arm64`; archives beside the script are used offline before attempting downloads.

The media runtime is currently arm64. A universal build would require independently cross-building and qualifying x86_64 tools, then using `lipo`; the app, its other runtimes and minimum OS must also support both architectures. The included x86_64 build option is not a claim that an Intel distribution has been qualified.
