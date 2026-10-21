# MVD library design preview

This separate, nonshipping app compiles the real `Sources/HarborApp` views unchanged and seeds four downloads and three folders only in memory. Transfer counts, progress, speeds, and quality settings are simulated test fixtures. No polling or broker starts, and production download history is never read. This is a visual/interaction harness, not a download-engine test.

```sh
python3 Tests/DesignPreview/build.py
bash Tests/DesignPreview/run.sh light 1440 920
bash Tests/DesignPreview/run.sh dark 1440 920
```

Close a preview before launching its replacement. The preview applies the requested launch dimensions after layout and logs its actual frame, content size and minimums. It overrides only its own window-sizing policy so `MVD_PREVIEW_FONT_SIZE=18 bash Tests/DesignPreview/run.sh dark 900 600` can inspect narrow reflow; production's content-minimum policy may require a wider window at large text sizes. Opening the inspector also exercises narrow list content. Settings, menus, list/grid switching, selection, search, folders, thumbnail hover, and completed playback use the production components. Mutation actions will fail against the isolated, nonexistent broker; do not use this harness to test downloads or Chrome setup.

The app has its own bundle/defaults domain, `io.harbor.downloads.designpreview`, and refuses to launch without a temporary support directory supplied by `run.sh`. Each launch creates its own temporary sample-download folder. There is no native host, browser registration, custom URL scheme, broker executable, or extension installation payload in this bundle. Quit it and remove the printed temporary directory to clean up; its independent preferences can be removed with `defaults delete io.harbor.downloads.designpreview`.

Fixtures are fetched once for QA reference and two small playable samples. Production `MediaThumbnail` still loads the three public HTTPS URLs normally; no local cache injection or localhost exception is added. Assets stay outside release packaging:

- Big Buck Bunny thumbnail: <https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg> (Blender official open movie).
- Nature-scene thumbnail: <https://i.ytimg.com/vi/6v2L2UGZJAM/hqdefault.jpg> (public YouTube thumbnail).
- Tears of Steel thumbnail: <https://i.ytimg.com/vi/R6MlUcmOul8/hqdefault.jpg> (Blender official open movie).
- Short video sample: <https://www.w3schools.com/html/mov_bbb.mp4>.
- Short audio sample: <https://www.w3schools.com/html/horse.mp3>.
