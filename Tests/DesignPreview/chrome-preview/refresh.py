#!/usr/bin/env python3
"""Refresh browser design fixtures from real production UI sources.

Only the generated preview copies get theme overrides and a mocked Chrome API.
"""
from pathlib import Path
import shutil

preview = Path(__file__).resolve().parent
root = preview.parents[2]
extension = root / "BrowserExtension"
for name in ("popup.html", "popup.css", "popup.js", "core.js", "overlay-ui.js", "README.md"):
    shutil.copy2(extension / name, preview / name)
shutil.copytree(extension / "icons", preview / "icons", dirs_exist_ok=True)

html = (preview / "popup.html").read_text()
html = html.replace('<link rel="stylesheet" href="popup.css">', '<script src="preview-theme.js"></script>\n  <link rel="stylesheet" href="popup.css">')
html = html.replace('<script type="module" src="popup.js"></script>', '<script src="mock-chrome.js"></script>\n  <script type="module" src="popup.js"></script>')
(preview / "popup.html").write_text(html)

light = {"ink":"#1c2025", "paper":"#fff", "sidebar":"#f2f3f4", "surface":"#f5f6f7", "field":"#fff", "line":"#e2e5e8", "muted":"#68727d", "accent":"#007e51", "accent-fill":"#008457", "mint":"#e8f5ef", "hover":"#eceff0", "error":"#b83a37"}
dark = {"ink":"#eceef0", "paper":"#1c1d20", "sidebar":"#232529", "surface":"#2b2d32", "field":"#24262b", "line":"#383b42", "muted":"#a2a9b3", "accent":"#5cdda8", "accent-fill":"#008457", "mint":"#203d32", "hover":"#30333a", "error":"#ffaaa2"}
css = (preview / "popup.css").read_text() + "\n/* Preview-only explicit scheme overrides; production follows the browser. */\n"
overlay_rules = "\n/* Preview-only explicit scheme overrides. */\n"
for name, palette in (("light",light),("dark",dark)):
    declarations = ";".join(f"--{key}:{value}" for key,value in palette.items())
    css += f':root[data-preview-theme="{name}"]{{color-scheme:{name};{declarations}}}\n'
    overlay_palette = {"--mvd-" + ("fill" if key == "accent-fill" else key):value for key,value in palette.items() if key != "surface"}
    overlay_declarations = ";".join(f"{key}:{value}" for key,value in overlay_palette.items())
    overlay_rules += f':host([data-preview-theme="{name}"]){{{overlay_declarations};--preview-scheme:{name}}}\n'
css += 'html{background:var(--paper)}\n'
(preview / "popup.css").write_text(css)
js = (preview / "overlay-ui.js").read_text()
style_end = js.index('\n`;')
overlay_rules += '.panel,.trigger{color-scheme:var(--preview-scheme,light dark)}\n'
js = js[:style_end] + overlay_rules + js[style_end:]
js = js.replace('node.__mvdOverlayOwned = true;', 'node.__mvdOverlayOwned = true; node.dataset.previewTheme = document.documentElement.dataset.previewTheme || "";')
(preview / "overlay-ui.js").write_text(js)
print(f"Refreshed actual Chrome UI copies in {preview}")
