# MVD private companion · development build 0.4.3

This **private, unpacked Chrome extension** adds a green SVG **Download this video** button inside the top-right corner of visible loaded video players, including paused/ended players. Clicking it opens an isolated in-browser options panel. MVD’s actual desktop extractor returns source formats, video qualities, audio modes and saved folder names/IDs; Download submits those selections and waits for a durable job ID.

YouTube and other supported public platforms are enabled in this private build at the user’s explicit request. This is **not a Chrome Web Store submission** and does not claim store approval, universal site compatibility or protected-media support.

## Install and enable

1. Build `build/MVD.app` using the repository instructions, then load this `BrowserExtension` folder with **Load unpacked** at `chrome://extensions`. Reload it when updating, then refresh pages that still contain older injected scripts. The current manifest version is `0.4.3`.
2. Register its exact extension ID explicitly:

   ```sh
   Scripts/install-chrome-host.sh YOUR_32_CHARACTER_EXTENSION_ID
   ```

   The script defaults to `build/MVD.app` and supports an optional absolute app path. It writes only the current user’s `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.harbor.downloads.json`. It never installs an extension or changes Chrome enterprise policies.
3. Open a public video page and click the MVD toolbar icon once. This uses Chrome’s `activeTab` grant to insert the player button on the current page without granting persistent all-site access. **Show video options on this page** opens a detected player’s options panel.
4. For later visits, choose **Enable automatic detection on this site**, or deliberately choose **Enable player buttons on all websites** and approve Chrome’s optional HTTP(S) host-permission prompt. No permission is auto-granted. Cross-origin iframe/CDN hosts can be approved separately through the observed-host selector.
5. Click the green button at the video’s top-right. Choose its actual format/quality, video-with-audio/video-only/audio-only mode, compatible output settings, and an existing MVD folder. Custom filesystem paths are not accepted from the extension; manage folders in the desktop app.

The desktop connection must report service `0.4.0`. Missing/incompatible host registration produces an error with a retry control instead of pretending that a job was sent. The native host’s internal identifier, executable name and `harbor-downloads` review scheme remain stable for compatibility, while the app is named MVD.

## Player controls and safety

The button uses the product’s actual green SVG download mark. Its options panel uses a **closed Shadow DOM** so website styling does not replace its controls. Native actions require trusted user click events; page script dispatching a synthetic click cannot start a download. Escape/Close dismiss the panel and restore focus. The page and player remain usable because the panel is non-modal. Container fullscreen is supported; native fullscreen of a bare `<video>` may not permit injected controls.

**Disable on this website** persists a domain choice in extension local storage, removes current controls, and blocks player resolve/enqueue actions on that site. **Re-enable on this website** in the popup restores controls. Disabling does not silently revoke unrelated Chrome permissions. **Hide this player button** dismisses just that player until navigation.

Each request is tied to the sender’s actual tab, frame and live document ID. The backend target is chosen from the registered player evidence, never an arbitrary content-message URL. YouTube watch/Shorts/embed URLs and inline-preview card links identify their exact provider video. Direct/manifest sources keep signed query strings intact. Multiple opaque unrelated players do not receive a guessed common page URL. Cross-origin frames get their own source/document checks and require Chrome access to that frame’s host.

Version 0.4.1 fixes Instagram reel feeds with preloaded sibling players. A focused video can use its actual reel/post permalink; unrelated hidden players cannot inherit it. The clicked player receives priority before collection limits, and signed posters are removed before compact player records when storage is full. Resolve and Download each carry a fresh snapshot of that selected player, so an older periodic inspection cannot replace its source. Same-document route changes validate the live frame URL and document ID, accommodating Chrome's original sender URL without accepting stale pages or documents.

Version 0.4.2 adds individual LinkedIn post routes and source discovery from the clicked player's configuration, CSS/image poster identity, and matching exposed progressive/manifest resources. A feed URL is never treated as a video. Unsupported page extraction can retry an actual source attributed to that player; unrelated feed sources and playback fragments cannot substitute for it. ISO segment MIME types and known DASH/HLS fragment routes do not count as downloadable videos. Some feed players still need their original post or may not expose an independent downloadable source.

Version 0.4.3 fixes selected-player source fallback dropping extensionless CDN URLs even when their media MIME was observed. The type is retained when an earlier duplicate observation had no type. If a player exposes its source only after playback starts, **Try again** takes a fresh snapshot without closing the options panel. All 63 extension regression tests pass. The latest reported failure is on Kling AI; its video has not been verified downloading. The installed engine has no Kling-specific extractor, so an actual exposed media source is required. This does not grant access to protected or authenticated content.

Ad markers and detected encrypted/DRM playback suppress the controls. Blob-only players need an associated supported provider page or exposed source; opaque, session-bound or protected sources can remain unavailable. No cookies, authorization headers, browser cookie databases or response bodies are exported. This does not promise that every playable stream is independently downloadable.

## Formats, folders and acknowledgments

Resolve fetches **real** `mediaPreview.formats` and `qualities` from the desktop. The panel does not invent a list of source resolutions. A specific format selection is sent by its returned ID; audio-only and exact-format selections omit conflicting video-quality fields. Fixed audio bitrate is offered only for M4A/MP3/Opus, while Original/WAV/FLAC clear it. Container/audio conversion still depends on the installed desktop tools and source compatibility.

Saved folders cross the bridge as safe names and opaque UUIDs. Absolute paths are neither accepted from content messages nor returned to website DOM. Default-folder selection omits `folderID` and uses the desktop setting. Formats may be bounded to the native-message cap; the panel discloses when additional formats are available in MVD.

A panel session is bound to one video/document. Download uses a durable idempotency key; retrying an unconfirmed action preserves the URL, format, quality, folder and request identity. Changing options during an unconfirmed attempt is rejected. “Accepted” appears only after a durable broker job ID returns. Closing Chrome or the panel does not own the lifetime of an accepted job. A separate **Review in MVD** context action can prefill the desktop composer; opening that review is distinct from accepting a job.

## Discovery, storage and permissions

Per-tab numeric badges count usable logical media candidates rather than segments or active jobs. DOM source URLs, video/poster/caption metadata and permitted response URL/Content-Type metadata are bounded and deduplicated. SPA/navigation changes clear stale sources. The network observer is installed only when `webRequest` exists and appropriate persistent host grants exist; unavailable optional APIs cannot prevent native bridge startup. It never blocks, modifies or cancels a browser request/download.

Optional site access registers only packaged isolated-world scripts on approved hosts. The all-sites option is an explicit Chrome permission request. `webNavigation` identifies active documents and iframe attribution; no global browsing-history database is kept. Main-frame inspection is independent of iframe permission failures, so an inaccessible child frame does not falsely mark the whole page unavailable.

Pending downloads, observations and short-lived panel sessions use Chrome session storage and disappear at browser exit. Disabled-site preferences alone use local persistent storage. Registries/panel sessions are bounded; network observations expire after ten minutes. Remote thumbnails use validated HTTP(S) URLs with anonymous/no-referrer image requests and labeled fallbacks. Titles are always text nodes, never page-supplied HTML.

Private/local/reserved destinations, credentialed URLs and unsupported schemes remain rejected at the extension/native boundaries. Native DNS screening is not connection pinning or full rebinding protection. Production signing, provider qualification and any distribution review remain separate gates.

## Verify

```sh
node --test BrowserExtension/tests/*.test.mjs
BrowserExtension/tests/run-framing-tests.sh
BrowserExtension/tests/run-native-host-tests.sh
swift build --target HarborNativeHost
```

Tests exercise bridge startup without optional webRequest/navigation APIs, exact player/provider association, iframe/document fences, private YouTube resolve/enqueue, actual options and opaque folders, durable retries, disabled-site persistence, protected-source suppression, metadata bounds and signed URL preservation. Native harnesses do not install an extension or launch an app. A real Chrome-to-MVD test is still required after changing the native registration or packaged binaries.
