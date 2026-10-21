# macOS distribution

The release targets Apple Silicon Macs running macOS 14 or later. It bundles yt-dlp, its pinned Python dependencies, Python, Deno, FFmpeg, and FFprobe. Users do not need Homebrew, Python, or developer tools. Intel Macs and other browser packages are not qualified by this release.

Current source version: **0.4.4, build 10**. It includes the Quiet Library redesign, preserved desktop System/Light/Dark/Custom appearance, and matching Chrome popup/player styling that follows the browser's preferred light/dark scheme. Artifact names below refer to this version; use its matching `build/ReleaseReports/release.json` and Apple submission reports to confirm signing and notarization results.

## Build

The build machine needs Apple Command Line Tools, Python 3, the pinned input archives described by `Packaging/Runtime/portable-tools.lock.json`, and the media source archives described by `media-sources.lock`.

```sh
bash Packaging/Runtime/build-media-runtime.sh arm64
python3 Packaging/Runtime/verify-media-runtime.py
python3 Scripts/prepare-portable-runtime.py
MVD_NOTARY_PROFILE=mvd-notary python3 -u Scripts/package-macos-release.py --qualify-online --notarize
```

`MVD_NOTARY_PROFILE` names an existing `notarytool` Keychain profile. No password, API key, or private signing key is stored in this repository. The pipeline selects the single valid Developer ID Application identity in Keychain. Set `MVD_SIGNING_IDENTITY` to an exact identity name or SHA-1 if several are available. Omitting `--notarize` produces signed artifacts without Apple's notarization assessment.

The pipeline builds `build/Release/MVD.app`, assembles Resources-relative tools and the Chrome setup payload, rejects non-system absolute dynamic-library dependencies, signs nested executables with hardened runtime and secure timestamps, runs tool checks, and seals the app. Deno receives its required JIT entitlement; the other executables do not receive it. The online qualification copies the app to a path containing spaces, uses system-only PATH and isolated broker state, resolves a public sample, downloads an MP3, and checks the resulting stream and unchanged app signature.

With `--notarize`, both the app and final DMG are submitted to Apple. Each submission must return Accepted before stapling, ticket validation, and Gatekeeper assessment. Reports are saved under `build/ReleaseReports`; `release.json` records the resulting artifact sizes and signing/notarization mode. Final artifact checksums are written to `dist/SHA256SUMS.txt` after stapling.

## Install

1. Open `dist/MVD-0.4.4-arm64.dmg` and drag MVD to Applications.
2. Open MVD and click **Connect Chrome** in the sidebar, or **Settings → Chrome**.
3. Prepare the companion. MVD copies its own extension files to `~/Library/Application Support/MVD/Chrome Companion` and registers the native host at the app's actual location.
4. At `chrome://extensions`, enable Developer mode, click **Load unpacked**, and choose the permanent folder shown by MVD. Open the extension popup to connect.
5. MVD shows its green connection tick only after a recent validated handshake through the matching host. Use **Check Connection** after reloading the extension or moving the app.

The DMG also includes **Chrome Companion** with a standalone installer helper and instructions. `dist/MVD-Chrome-Installer-0.4.4.zip` contains the complete helper package. `dist/MVD-Companion-0.4.4.zip` contains only the extension runtime and must be extracted before Chrome can load it. Do not load an extension directly from the mounted DMG; its files must remain available after ejecting it.

The private package uses a stable public manifest key. It does not silently install or enable extensions, modify enterprise policies, grant site permissions, or register other browsers. A development source install may have a different ID; the host pairs with one extension at a time. Reload the companion and refresh existing video pages after replacing its runtime. Unpacked installs do not receive store updates.

An explicit browser download brings forward the exact registered MVD app only after the broker confirms its job ID. The activation route reveals that existing job and never queues another copy. Handshakes, format previews, rejected requests, and unconfirmed jobs do not trigger download activation. An app activation failure does not revoke the accepted download.

The 0.4.4 source passes all 65 JavaScript extension tests and `Tests/Integration/native_activation.sh`. The activation harness validates policy and relocated-app identity without launching an app; browser design previews use mock handoffs. The final 0.4.4 build 10 app and DMG were signed with Raman Singh’s Developer ID, accepted by Apple, and stapled. The release also passed moved-app YouTube-to-MP3 qualification; final reports and checksums are preserved in `build/ReleaseReports/0.4.4`. A rebuilt artifact needs its own fresh qualification and Apple assessment. The reported Kling AI case remains unverified, and website/provider limitations still apply.

## Runtime and licenses

`Contents/Resources/runtime.json` contains only Resources-relative provider paths. The Python launcher resolves its adjacent isolated interpreter at runtime; FFmpeg and Deno have no Homebrew dependency. Explicit developer environment overrides remain available but are absent from the release manifest.

Third-party notices are in `MVD.app/Contents/Resources/Licenses`. The DMG includes `MVD-media-sources-9.0.2-arm64.tar.gz` containing the exact media source archives, licenses, configuration reports, checksum lock, and offline rebuild instructions. Python and Deno notice inventories preserve pinned upstream attribution and provenance. Bundled tools keep their own licenses.

Relocation and isolated integration checks run on the build Mac. They are not a clean-room test on a separate Mac or a claim that every website is supported.
