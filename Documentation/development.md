# Development notes

These notes describe MVD 0.4.4, build 10. The [reserved-rights license](../LICENSE) allows source inspection and building/running the unmodified source for personal or internal use. Changes require permission. Public source visibility does not grant permission to modify, redistribute, rebrand, or resell MVD. Third-party components keep their own licenses.

For everyday installation and use, start with [getting started](getting-started.md) or the [tutorials](tutorials.md).

## Build locally

Use an Apple Silicon Mac with macOS 14 or later, a Swift 6 toolchain with Apple Command Line Tools, Python 3, FFmpeg, and Deno. Node.js is needed for the JavaScript regression tests. The packaged app already includes its media tools; these dependencies are for local development.

```sh
git clone https://github.com/kwebby/mac-video-downloader.git
cd mac-video-downloader
Scripts/setup-tools.sh
Scripts/build-app.sh
open build/MVD.app
```

`setup-tools.sh` creates the pinned yt-dlp and EJS Python environment at `~/Library/Application Support/MVD/Runtime/python`. FFmpeg and Deno are discovered separately. Settings > Media Tools shows the selected executables.

Set `HARBOR_YTDLP_PATH`, `HARBOR_FFMPEG_PATH`, or `HARBOR_DENO_PATH` before building to select trusted installations. `HARBOR_TOOL_RUNTIME_DIR` selects a different runtime parent directory. Keep this environment outside protected project folders: GUI-launched Python previously blocked during initial file access when its environment lived inside Downloads. The Application Support runtime avoids that dependency without changing macOS privacy settings.

`Scripts/build-app.sh` creates an ad hoc signed development bundle at `build/MVD.app`. Its tool paths refer to this Mac. Set `MVD_BUILD_CONFIGURATION=release` for a release-optimized local build, or use an absolute `.app` path in `MVD_BUILD_APP_DIR` to choose another output. The separate [distribution pipeline](distribution.md) assembles portable tools, signs the app, and can submit it for notarization.

The public app and executable are named MVD. Internal Swift modules, the `io.harbor.downloads.dev` bundle identifier, developer environment variables, and the `Harbor` settings namespace retain their earlier names for history and settings compatibility.

## Data and background service

The default destination is `~/Downloads/MVD`. An exact old `~/Downloads/Harbor` default migrates for new jobs; custom locations and existing saved paths stay intact. Jobs, folder shortcuts, and settings live in `~/Library/Application Support/Harbor`.

A detached per-user broker owns accepted downloads. Closing the interface does not stop that broker. Login registration with `SMAppService` is not implemented. To deliberately stop the broker and pause active jobs:

```sh
build/MVD.app/Contents/MacOS/harborctl shutdown
```

Chrome setup stages its runtime at `~/Library/Application Support/MVD/Chrome Companion` and registers the exact native host for the current user. See the [extension development notes](../BrowserExtension/README.md). Reload the unpacked companion and refresh existing video pages after changing its files. A source-loaded extension can have a different ID from the packaged companion.

## Implemented scope and limits


| Area | Current behavior |
|---|---|
| Native app | Quiet Library list/grid views, sidebar/folder filters, sorting, inspector, search, multi-select controls, URL review, settings, and menu bar |
| Acquisition | Automatic direct-file or yt-dlp provider routing; typed desktop YouTube URLs are enabled |
| Media | yt-dlp/EJS/Deno downloads, real previews/format metadata, exact selected-height or source-format requests, FFmpeg assembly/conversion |
| Output modes | Video with audio, silent video, original/extracted audio, explicit audio conversion/bitrate, compatible container remux |
| Bulk | Bounded multi-URL review, per-item options/destination/errors/selection, persistent independent queueing |
| Folders | Saved destination shortcuts with editable names, paths, SF Symbols, colors, and sidebar counts; removal keeps saved files |
| Acceleration | Opt-in validated direct ranges, at most four parts per eligible file; up to four media fragments; logical broker budget of eight |
| Persistence | SQLite sole-writer broker, committed acceptance, intent-aware retry idempotency, removed-request tombstones, and publication recovery receipts |
| Files | Streaming staging, response-length checks, no-clobber publication, collision suffixes, and completed-file preservation |
| Controls | Queue concurrency, pause/restart, cancel, retry, persistent history, and explicit restart for changed output options |
| Page fetch | Static HTML limited to 1 MiB and 100 link candidates, plus page-provider resolution |
| Proxy | Unauthenticated media-tool HTTP(S)/SOCKS proxy URL; direct transfers reject configured proxies instead of bypassing them |
| Appearance | Persistent light/dark/system/custom modes, colors, fonts, native icons, and MVD branding |
| Chrome | Matching light/dark popup and per-player chooser, real media options, saved-folder selection, confirmed handoff that reveals the accepted job, and per-site disable controls |

**Direct-file resume still restarts from the beginning.** Range acceleration verifies a fresh representation within one attempt; it does not persist a cross-restart range map. Provider media jobs can reuse available yt-dlp partials until changed options explicitly invalidate them.

Provider support changes with websites. DRM-protected streams and general WebRTC playback are unsupported. No universal-site compatibility or fixed speed multiplier is claimed. Live recording, authenticated sessions/proxies, subtitle/audio-track selection, arbitrary video transcoding, global bandwidth limits, scheduling, full site crawling, additional browser support, and production background registration need further implementation or qualification.

## Verification


```sh
swift build
python3 Tests/Integration/downloads.py
node --test BrowserExtension/tests/*.test.mjs
bash BrowserExtension/tests/run-framing-tests.sh
bash BrowserExtension/tests/run-native-host-tests.sh
bash Tests/Integration/native_activation.sh
# Optional online check after registering the exact extension ID:
python3 Tests/Integration/native_browser_bridge.py YOUR_EXTENSION_ID
bash Tests/Integration/media_metadata.sh
swift test  # requires full Xcode with XCTest; some command-line-tools SDKs omit it
```

The executable integration suite contains 13 cases. It starts an isolated broker and local HTTP server, generates owned MP4/HLS fixtures with FFmpeg, and checks:

1. Durable idempotency, exact bytes, and filename collisions.
2. Pause and safe direct-file restart.
3. Truncated responses never published as complete files.
4. Invalid inputs rejected.
5. Jobs retained across broker restart.
6. Real media-worker output.
7. Preview-derived quality selection and actual output height.
8. Bulk queue concurrency.
9. Paginated long-URL history and bounded acknowledgments.
10. Audio-only MP3 at 192 kbps and silent-video stream composition, checked with ffprobe.
11. Folder creation/edit/removal and per-job destinations without deleting completed files.
12. Overlapping validated direct ranges, exact bytes, and safe fallback for ignored ranges, changed representations, and weak/malformed ETags.
13. Updating a paused job's options/destination, then restarting without mixing data.

Media cases may skip if required fixture tools are unavailable; inspect the test output before claiming a complete pass. Fixtures are removed afterwards unless `HARBOR_KEEP_TEST_FILES=1` is set. Unit tests are a separate check: `swift test` could not run on the development Mac's command-line-tools-only installation because XCTest is unavailable.

An earlier packaged development smoke test completed a public 19-second YouTube download and verified a 19.021-second output containing audio and video with ffprobe. That qualifies the tested case only; it does not establish support for every YouTube video, account state, or current provider change. The sample files were removed afterwards.

Version 0.4 qualification also passed all 13 download integration cases, 35 extension tests, native-host framing/contract checks, and a headless SwiftUI folder-transition regression. An online bridge test used the registered packaged host to resolve a public YouTube video, reject a request without an explicit gesture, enqueue one idempotent MP3 download, and verify its audio-only output with ffprobe. A separate live Chrome test selected MP3 at 128 kbps and the saved **New** folder, received the desktop acknowledgment, and completed the download in MVD. Per-site disable and re-enable were also checked in Chrome. The final app signature and property list validate.

Version 0.4.2 passes all 13 download integration cases and 60 extension tests. Its metadata regression checks reported/probed qualities, codecs, bitrates, audio/video isolation and exact-format validation. A registered packaged-host test resolved a public LinkedIn sample, selected its real 720p source ID, and completed an audio-only MP3 verified with FFprobe, including idempotent retry and gesture rejection in isolated temporary state. Native UI testing verified audio preview playback/close/reopen and video handoff to the default Mac app.

Version 0.4.3 builds and validates its app signature/property list, and all 63 extension tests pass. An isolated native UI preview checked populated grid cards in light/dark mode, selection across view changes, empty-folder recovery, accessible card actions, and audio playback from artwork. Preview entries never entered the user's broker queue and the preview artifacts were removed after qualification. The requested support links were verified as native links to the exact supplied destinations; no checkout was submitted. The reported Kling AI download remains unverified.

The portable 0.4.3 build 9 adds bundled media tools and guided Chrome setup with verified connection status. Swift compilation, 65 extension tests, native-host framing/contract checks, and the standalone Chrome connection harness pass. The harness checks exact caller registration, moved-host rejection, stable public-key identity, stale/dead-process receipts, private receipt permissions, and symlink refusal without changing the user's Chrome registration. A moved signed app with system-only PATH resolves a public YouTube sample and completes an audio-only MP3 verified with bundled FFprobe; its signature remains valid afterwards. Native UI inspection confirms the sidebar setup button, three-step sheet, truthful repair state for a host registered to another app, connection recheck, and Done/close controls. The full XCTest target still requires an SDK with XCTest.

Version 0.4.4 build 10 passes all **65 JavaScript extension regression tests** and the standalone native activation harness. The activation harness checks explicit gesture and correlated acknowledgment requirements, confirmed-job-only activation links, and exact relocated-app validation; it does not launch an app or change the user's Chrome registration or downloads. Isolated design fixtures exercise the populated native library and Chrome popup/player controls with mock data. These fixtures do not establish a live download on every website. Kling AI remains unverified. The final 0.4.4 app and DMG are signed with Developer ID Application: Raman Singh (SG77J9KKYK), accepted by Apple, and stapled. The moved-app YouTube-to-MP3 qualification passed. Matching release reports are under `build/ReleaseReports/0.4.4`; see [distribution instructions](distribution.md) and [design fixture notes](../Tests/DesignPreview/README.md).

## Architecture and next work


```text
MVD UI (HarborApp) ─┐
harborctl ──────────┼─ private user socket ─ HarborBroker ─ SQLite
Chrome → Host ──────┘                             ├─ URLSession direct/range workers
                                                 └─ yt-dlp + EJS/Deno + FFmpeg
```

The broker owns the queue/database. The local socket uses private filesystem permissions, framing limits, timeouts, and same-UID peer checks; signed peer identity/XPC hardening remains a release gate. The broker invokes trusted tools with argument arrays, disables yt-dlp user configuration/plugins, and uses cancellable process groups. A standard console launcher may use a fixed, quoted shell stub when its Python path contains spaces; URLs and options are never inserted into user-supplied shell commands. Tool output is bounded, errors are redacted, and publication verifies output paths.

The research and feature ledger are in [plan.md](../plan.md). It remains a research baseline rather than a shipped-feature claim. Next milestones include durable validated range resume, direct proxies, richer provider/manifest qualification, explicit track/subtitle selection, session-aware browser capture, queues/schedules/rules, a bounded site grabber, and automatic updates.

Third-party tools retain their independent licenses. The portable release includes its own FFmpeg build with GPL/nonfree features disabled, separate from the developer's Homebrew installation. Runtime pins, notices, and media source/rebuild materials are included with the release; see [runtime documentation](../Packaging/Runtime/README.md).

## Design fixtures

[Tests/DesignPreview](../Tests/DesignPreview/README.md) provides isolated native UI data. Its Chrome fixtures copy the production popup and player chooser, then replace only the Chrome/desktop boundary with mock responses. Explicit light/dark overrides exist in the preview copies. Production Chrome surfaces follow the browser's preferred color scheme.

The fixtures are useful for layout, overflow, selection, keyboard controls, and error states. They neither enqueue into the user's broker nor qualify live provider compatibility. The [Chrome fixture notes](../Tests/DesignPreview/chrome-preview/PREVIEW.md) describe refresh and local serving.

## Project rights and support

MVD is source available with reserved rights. Read [LICENSE](../LICENSE) before changing or redistributing it. The shipped Python, yt-dlp, EJS, Deno, FFmpeg, FFprobe, and other third-party components retain their separate licenses and notices.

Created by [Ramanpal Singh](https://kwebby.com). For permission requests, project help, or custom work, visit [Kwebby](https://kwebby.com/services). You can also [support MVD with a donation](https://checkout.dodopayments.com/buy/pdt_0NqDCEkv5kQm3ei5prGCE?quantity=1).
