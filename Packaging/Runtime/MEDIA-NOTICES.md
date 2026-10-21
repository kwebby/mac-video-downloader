# MVD bundled media tools

MVD invokes FFmpeg and FFprobe as separate command-line programs. It does not link its application executable against their libraries.

- **FFmpeg / FFprobe 9.0.2** — GNU Lesser General Public License version 2.1 or later. Official source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz ; project: https://ffmpeg.org/ . This build disables GPL, nonfree and version3 components and automatic external-library detection.
- **LAME 4.0** — GNU Library General Public License version 2 or later. Official source: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz ; project: https://lame.sourceforge.io/ . Only the encoding library is included; its decoder and standalone frontend are disabled.
- **Opus 1.6.1** — BSD 3-Clause license with upstream royalty-free patent notices. Official source: https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz ; project: https://opus-codec.org/ . Optional neural DRED, deep PLC and OSCE features are disabled.

The included tools are built from the exact unmodified source archives retained beside this notice. Their SHA-256 digests and download URLs are pinned in `media-sources.lock`. Corresponding configure/build commands are in `build-media-runtime.sh`; configure reports are retained in `reports/`. License texts are included in `licenses/`.

FFmpeg also contains code under compatible permissive licenses, including parts of the Independent JPEG Group's work. This software is based in part on the work of the Independent JPEG Group. No changes were made to upstream IJG-derived files. The full source archive includes the original copyright notices for every file, including the IJG-derived files and other permissively licensed components.

The FFmpeg tools include static LGPL and BSD libraries, not external Homebrew runtime libraries. The complete corresponding source and build instructions permit rebuilding/replacing these separate tools. The application must not prohibit reverse engineering of these library components for debugging modifications. Redistributors must include these license notices and exact corresponding sources/build materials with the binary distribution, and preserve the source-download notice beside any website download link as described at https://ffmpeg.org/legal.html .

HTTPS uses Apple's system SecureTransport and Security/CoreFoundation frameworks. Other dynamic dependencies must resolve only to macOS system libraries/frameworks. This build provides native AAC, FLAC and PCM audio encoders plus libmp3lame and libopus, and supports stream-copy/remux for downloaded video. Video transcoding encoders are intentionally omitted; MVD's current video output operations preserve the source codecs.

Build requirements: macOS with Apple Command Line Tools, `make`, and `pkg-config` (metadata lookup at build time only). Building does not install files globally. Run `bash build-media-runtime.sh arm64`; `x86_64` can be built separately using Apple's cross compiler and combined with `lipo` only after separate qualification. The initial release artifacts are arm64 and target macOS 13.0 or later.
