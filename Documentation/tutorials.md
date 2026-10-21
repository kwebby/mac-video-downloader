# MVD tutorials

Here are the everyday workflows, from one video to a tidy library. If you have not installed MVD or paired Chrome yet, start with [getting started](getting-started.md).

## Download your first video

1. Copy a supported public video page URL.
2. Paste it into MVD and click **Review Link**, or open **Add URL** with `⌘N`.
3. Check the resolved title and thumbnail so you know you picked the right video.
4. Choose **Video + Audio**.
5. Pick a quality such as 720p or 1080p from the source's actual choices. For a particular codec or rendition, choose its exact source format instead.
6. Keep **Auto** for the output container, or choose a compatible MP4, MKV, or WebM container.
7. Confirm the folder and click **Download**.

Selecting an exact source format fixes its resolution. Return the source-format choice to Automatic when you want the separate quality control to decide again. A fixed file can have one original representation. Container changes preserve the source codecs; incompatible combinations report an error.

After completion, hover the thumbnail and click **Play**. Video opens in the Mac's default associated app. **Show in Finder** opens the saved location.

## Save an MP3 at 128 kbps

1. Review the video or audio URL in MVD.
2. Set the output mode to **Audio Only**.
3. Choose **MP3** as the audio format.
4. Choose **128 kbps** for the audio bitrate.
5. Pick the destination and click **Download**.

MVD downloads the chosen source and uses its bundled FFmpeg to create the MP3. M4A and Opus also support bitrate choices. Original audio, WAV, and FLAC have no fixed bitrate setting. Converting a low-quality source to a larger bitrate cannot restore missing detail.

Completed audio items show audio artwork and a play control. Click it to open the native audio preview.

## Save a video without audio

1. Review the video URL.
2. Choose **Silent Video** in MVD, or **Video only** in the browser chooser.
3. Select a source format or quality and a compatible container.
4. Confirm the folder and download.

The finished file contains the video track without an audio track. This still depends on the selected source being available and compatible with the output container.

## Download several links together

1. Click **Bulk URLs**, or press `⇧⌘N`.
2. Paste one URL per line. MVD accepts up to 50 unique links and removes exact duplicates.
3. Review the results. Each video gets its own quality selection.
4. Open **Options…** for a row to change its output mode, format, audio settings, acceleration, and destination.
5. Select the rows you want and click **Download Selected**.

MVD resolves a bounded number of previews together and queues each accepted request independently. A failed URL stays visible for correction and does not discard the other links. `⇧⌘V` routes a copied single link to review or several links to bulk entry.

## Organize downloads with folders

1. Click **+** beside Folders in the sidebar.
2. Select a save location. Use **New Folder** in the macOS chooser to create a directory if needed.
3. Give the shortcut a name, icon, and color, then save it.
4. Choose that shortcut in a download's destination row.
5. Click the folder in the sidebar to see downloads assigned to it.

Right-click a folder shortcut to edit it, open it, or remove the shortcut. Removing the shortcut keeps files on disk. Editing a shortcut does not move previously saved files or rename the real directory.

To change the default destination for future downloads, open **Settings > General**. Existing downloads keep their recorded paths.

## Use the browser companion

After [connecting Chrome](getting-started.md#connect-the-chrome-companion):

1. Open a public video page and click the MVD toolbar icon.
2. Compare the numbered videos by thumbnail, title, page, and source.
3. Choose a row's **Video options**, or click **Download this video** on that player.
4. Pick video with audio, video only, or audio only.
5. Choose the actual source format, quality, audio output/bitrate where available, and a saved MVD folder.
6. Click **Download in MVD** and wait for confirmation.

A confirmed download brings forward the exact paired MVD app and selects the accepted job. The desktop activation opens that existing job without enqueuing a duplicate. Closing Chrome afterwards does not cancel an accepted download.

For a link you already copied, use **Have another link?** in the popup. **Review link in MVD** opens the desktop review flow. **Review this page in MVD instead** offers the same desktop fallback for the current page.

The browser receives saved folder names and IDs. Create or edit folder shortcuts in MVD when you need a new destination.

### Turn off MVD on one website

1. Open the companion popup on that website.
2. Expand **Website controls**.
3. Click **Disable on this website**.

MVD removes its player buttons and stops player resolution on that site. Open the same controls and choose **Re-enable on this website** to restore them. This preference does not revoke unrelated Chrome permissions. **Hide this player button** in a chooser hides only that player until navigation.

### Keep detection available on later visits

Under **Website controls**, allow automatic detection on the current site. Chrome asks you to approve that host. A separate all-websites option is available when you explicitly want broader access. Observed cross-origin media hosts can need their own permission; allow the selected host, then play the video again to generate new requests.

Chrome permission approval stays in Chrome. MVD does not export browser cookies or authorization headers.

## Pause, retry, or change a download

Select one or more items and use the available pause, resume/retry, or cancel action. The context menu also offers source information, Finder reveal, and removal from the list.

For output changes, use **Edit Download Options…**. An active transfer asks to restart with the new settings. A paused job remains paused after applying. Incompatible partial data is discarded so the result does not mix different formats. A completed item uses **Download New Copy** and preserves the saved file.

Direct-file resume currently restarts from byte zero. Provider downloads can reuse compatible yt-dlp partial data. Removing a list entry is separate from deleting saved files.

## Use a media proxy

1. Open **Settings > General**.
2. Enter a complete unauthenticated HTTP(S) or SOCKS proxy URL, such as `http://127.0.0.1:8080` or `socks5h://127.0.0.1:1080`.
3. Save the settings and start a media download.
4. Clear the field and save when you want a direct media connection again.

Proxy support currently applies to the media tools. Direct file transfers reject a configured proxy because direct-transfer proxy routing is not implemented. Authenticated proxies and browser-session forwarding are unsupported. Extra FFprobe preview inspection is skipped when a proxy is set so it cannot create a direct connection around that setting.

## Try download acceleration

Enable **Accelerate transfer** during review, or select an existing download and use the bolt control.

For eligible direct files, MVD validates the server's byte ranges and representation before using up to four parts. Supported HLS/DASH downloads can use up to four concurrent media fragments. Sources that do not support the direct range checks fall back to an ordinary fresh transfer.

Changing acceleration on an active transfer requires a restart. Paused jobs stay paused. Acceleration cannot guarantee a speed increase: the server, network, disk, and later audio/video processing can still be the limit.

[How acceleration works and what was tested](acceleration.md)

## Change the look

Open **Settings > Appearance** for System, Light, Dark, and Custom modes. Custom mode includes a light/dark base, accent/background colors, font, and text size. The library also offers list/grid views and saved density preferences.

The Chrome popup and player chooser follow the browser's preferred light/dark scheme.

## When a video will not download

MVD uses provider extraction and observed media sources. Website changes can affect either route, so support varies by site, video, and session.

- Start playback, wait a moment, and reopen the player's download button. Some sources appear only after playback begins.
- Open the video's original post instead of a broad feed containing several players.
- Check that MVD and the Chrome companion are updated together. Reload the extension and refresh existing tabs after updating.
- If the site exposes a supported public file or manifest URL, review that exact URL in MVD.
- If the error says the app is unavailable, recheck the Chrome connection in the installed desktop app.

DRM-protected playback, general WebRTC capture, and opaque browser-only sources can remain unavailable. Authenticated sessions and cookie forwarding are not implemented. There is no every-website download guarantee. The reported Kling AI video remains unverified.

For a useful bug report, include the public page URL, the app/extension version, and the error text. Keep credentials, private media links, and session tokens out of public issues.

## Support MVD

MVD is created by [Ramanpal Singh](https://kwebby.com). [Hire Kwebby](https://kwebby.com/services) for project work, or [donate](https://checkout.dodopayments.com/buy/pdt_0NqDCEkv5kQm3ei5prGCE?quantity=1) to help keep MVD moving.

The project is [source available with reserved rights](../LICENSE). Permission is required for modification, redistribution, rebranding, or resale. Third-party license terms remain separate.
