# Getting started with MVD

You only need a supported Mac and a link to try your first download. MVD 0.4.4 supports **Apple Silicon Macs running macOS 14 or later**. The official app includes its media tools.

[Back to the project](../README.md) · [Detailed tutorials](tutorials.md) · [Development notes](development.md)

## Install the app

1. Open the [v0.4.4 release](https://github.com/kwebby/mac-video-downloader/releases/tag/v0.4.4).
2. Download **MVD-0.4.4-arm64.dmg**.
3. Open the disk image and drag **MVD** into **Applications**.
4. Open **MVD** from Applications. Once it is copied, you can eject the disk image.

The Chrome companion is included in the app and DMG. You can set it up after your first desktop download.

## Install from terminal

For the quick route:

```sh
curl -fsSL https://raw.githubusercontent.com/kwebby/mac-video-downloader/main/Scripts/install.sh | bash
```

The installer finds the latest GitHub release, downloads the matching app, verifies the published checksum, and copies MVD into Applications. It does not use `sudo` by default. Read any installer output if an existing app or folder permissions need attention.

You can download and inspect the script before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/kwebby/mac-video-downloader/main/Scripts/install.sh -o mvd-install.sh
less mvd-install.sh
bash mvd-install.sh
```

To choose a different app folder or pin a version:

```sh
bash mvd-install.sh --version v0.4.4 --destination "$HOME/Applications"
```

Use `--download-only` to save a verified DMG without installing it. Use `--replace` only when you mean to replace an existing copy. Before an update, quit MVD and let transfers finish. Closing the interface can leave its background service running. To deliberately stop that service and pause active jobs:

```sh
"/Applications/MVD.app/Contents/MacOS/harborctl" shutdown
bash mvd-install.sh --version v0.4.4 --replace
```

The installer never quits MVD or stops downloads for you. It verifies the release checksum, Apple signature, developer identity, and Gatekeeper notarization before copying the app.

For a manual v0.4.4 download and checksum check:

```sh
curl -fL https://github.com/kwebby/mac-video-downloader/releases/download/v0.4.4/MVD-0.4.4-arm64.dmg -o MVD-0.4.4-arm64.dmg
curl -fL https://github.com/kwebby/mac-video-downloader/releases/download/v0.4.4/SHA256SUMS.txt -o SHA256SUMS.txt
awk '$2 == "MVD-0.4.4-arm64.dmg" { print }' SHA256SUMS.txt | shasum -a 256 -c - && open MVD-0.4.4-arm64.dmg
```

A matching checksum prints `MVD-0.4.4-arm64.dmg: OK`. Then drag the app into Applications.

## Make your first download

1. Copy a complete video URL, such as a supported public YouTube or Vimeo page.
2. Paste it into MVD's URL bar and click **Review Link**. You can also open **Add URL** with `⌘N`.
3. Wait for the title, thumbnail, and available source information.
4. Choose **Video + Audio**, then select an available quality or exact source format.
5. Check the destination folder and click **Download**.

A source can offer only one representation. Resolutions and formats come from the actual media, so 1080p is available only when the source provides it. Recognized video and audio file URLs also open media review. Other direct file types may start immediately using the visible destination.

When a media download finishes, hover its thumbnail and click **Play**. Videos open in your Mac's default app. Audio opens MVD's native audio preview. Use **Show in Finder** to reveal the saved file.

## Pick a download folder

New downloads use `~/Downloads/MVD` by default. Change it in **Settings > General**.

For a single download, use the destination row during review to select another location. Saved folder shortcuts appear in the sidebar and the download's destination menu. The sidebar **+** beside Folders creates a shortcut with your chosen name, icon, and color. Use **New Folder** in the macOS folder chooser when you want to create a real folder on disk.

[Folder tutorial](tutorials.md#organize-downloads-with-folders)

## Connect the Chrome companion

1. Open MVD from its installed location in Applications.
2. Click **Connect Chrome** in the sidebar, or open **Settings > Chrome**.
3. Follow the setup steps to prepare the companion and its desktop bridge.
4. In Chrome, visit `chrome://extensions` and enable **Developer mode**.
5. Click **Load unpacked** and choose the permanent companion folder MVD reveals.
6. Open the MVD toolbar popup once. Return to the app and use **Check Connection** if needed.

MVD stages the extension at `~/Library/Application Support/MVD/Chrome Companion`. Keep that folder in place. A green checkmark means a recent handshake succeeded with the native host registered to this app. Copied extension files alone do not count as a connection.

Open a public video page and click the companion icon to inspect that tab. The popup shows numbered video sources with thumbnails and titles. Use **Video options**, or the player's **Download this video** button, to choose quality, output, and a saved folder.

For automatic buttons on later visits, open **Website controls** in the popup and allow the current site. You can also deliberately choose the all-websites option. Chrome controls those permission prompts. **Disable on this website** turns off MVD's controls for that site until you re-enable it.

The complete [Chrome installer ZIP](https://github.com/kwebby/mac-video-downloader/releases/download/v0.4.4/MVD-Chrome-Installer-0.4.4.zip) contains a standalone setup helper. The smaller [runtime ZIP](https://github.com/kwebby/mac-video-downloader/releases/download/v0.4.4/MVD-Companion-0.4.4.zip) contains only the extension files. Extract either package before use. Loading files from a mounted DMG will stop working after it is ejected.

## Make it feel like your Mac

Open **Settings > Appearance** and choose **System**, **Light**, **Dark**, or **Custom**. Custom mode lets you choose a light/dark base, accent, background, font, and text size. Row density and the list/grid view choice are saved locally.

The Chrome popup and player chooser follow the browser's preferred light/dark scheme. Chrome's theme choice is independent of MVD's custom desktop appearance.

## If something needs attention

- **MVD cannot reach the download service:** use **Reconnect** in the app. Closing the window normally leaves accepted downloads running.
- **Chrome cannot connect:** open the installed app, check **Settings > Chrome**, and verify that the extension points to the same app. Moving MVD can require setup again.
- **A page shows no video:** start playback, wait a moment, and refresh the popup. Try the video's original post when a feed contains several players.
- **An updated extension behaves like the old one:** reload it at `chrome://extensions` and refresh existing video tabs.
- **A format or site is unsupported:** use the [troubleshooting notes](tutorials.md#when-a-video-will-not-download). Protected playback cannot be downloaded by MVD.

## Support and project rights

Created by [Ramanpal Singh](https://kwebby.com). [Hire Kwebby](https://kwebby.com/services) for custom work, or [donate to support MVD](https://checkout.dodopayments.com/buy/pdt_0NqDCEkv5kQm3ei5prGCE?quantity=1).

MVD is [source available with reserved rights](../LICENSE). You can inspect the source and use the official app for personal/internal use. Modification, redistribution, rebranding, and resale require permission. Third-party software keeps its own license terms.
