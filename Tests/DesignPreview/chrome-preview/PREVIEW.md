# Chrome UI design fixture

Run `python3 Tests/DesignPreview/chrome-preview/refresh.py` after changing a production Chrome UI file. This copies the real HTML, CSS, runtime popup module, core URL validation module, existing icons, and in-player UI, then injects a mock Chrome API in **preview copies only**.

Serve the repository root through a local HTTP server, and visit `/Tests/DesignPreview/chrome-preview/index.html`. No server is started automatically.

The real popup is 420 px wide and scrolls at a maximum height of 600 px. Use `?theme=light` or `?theme=dark` for explicit, independent preview schemes. Production UI follows the browser's preferred color scheme. Optional popup fixture flags: `offline=1`, `empty=1`, `disabled=1`, `long=1`.

`player.html` invokes the actual closed-shadow chooser with mocked 1080p/720p formats, audio renditions, and three folder labels/IDs. `player-narrow.html` embeds it at an actual 320 px viewport to exercise field stacking. `error=1` simulates a resolve failure. `window.__MVDPreview.calls` records commands and selected download options in both fixtures.

Remote thumbnail references use public YouTube video posters. Player context uses a public Blender open-movie poster URL. Screenshot credits are in Documentation/Screenshots/README.md. Mocks neither request browser permissions nor contact MVD or its broker, and no media download starts.
