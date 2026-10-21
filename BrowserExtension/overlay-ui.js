(() => {
  if (globalThis.__MVDOverlayUI) return;
  const STYLE = `
:host{font:13px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif!important;color-scheme:light dark;--mvd-ink:#1c2025;--mvd-paper:#fff;--mvd-sidebar:#f2f3f4;--mvd-field:#fff;--mvd-line:#e2e5e8;--mvd-muted:#68727d;--mvd-accent:#007e51;--mvd-fill:#008457;--mvd-mint:#e8f5ef;--mvd-hover:#eceff0;--mvd-error:#b83a37;color:var(--mvd-ink)!important}
*{box-sizing:border-box}.panel,.trigger{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:13px;color-scheme:light dark}button,select{font:inherit;color:inherit}button{cursor:pointer}button:disabled{opacity:.48;cursor:default}button:focus-visible,select:focus-visible{outline:2px solid var(--mvd-accent);outline-offset:3px}button:active:not(:disabled){filter:brightness(.96)}[hidden]{display:none!important}
.trigger{pointer-events:auto;display:flex;align-items:center;gap:8px;min-height:38px;border:1px solid var(--mvd-line);border-radius:9px;background:var(--mvd-paper);color:var(--mvd-ink);padding:7px 11px 7px 8px;box-shadow:0 2px 10px #11182025;font-size:12px;font-weight:600;white-space:nowrap}.trigger:hover{background:var(--mvd-mint);border-color:var(--mvd-accent)}.trigger svg{width:22px;height:22px}
.panel{pointer-events:auto;position:fixed;right:12px;top:12px;width:min(420px,calc(100vw - 24px));max-height:calc(100vh - 24px);overflow:auto;overscroll-behavior:contain;scrollbar-width:thin;background:var(--mvd-paper);border:1px solid var(--mvd-line);border-radius:14px;box-shadow:0 16px 55px #11182040;color:var(--mvd-ink);line-height:1.4}
header{display:flex;gap:10px;align-items:center;position:sticky;top:0;z-index:1;padding:16px 20px;background:var(--mvd-sidebar);border-bottom:1px solid var(--mvd-line)}header>svg{width:31px!important;height:31px!important;flex:0 0 31px}header strong{font-size:19px;letter-spacing:-.6px}header span{font-size:11px;color:var(--mvd-muted)}header button{display:grid;place-items:center;flex:0 0 28px;width:28px;min-height:28px;margin-left:auto;background:none;border:0;border-radius:6px;font-size:22px;font-weight:300;color:var(--mvd-muted);line-height:1;padding:2px}header button:hover{background:var(--mvd-hover)}
.body{padding:18px 20px 20px}.eyebrow{margin:0 0 8px;font-size:10px;font-weight:500;color:var(--mvd-muted)}h2{margin:0 0 6px;font-size:16px;font-weight:650;letter-spacing:-.2px;line-height:1.4;overflow-wrap:anywhere}.source{margin:0 0 14px;color:var(--mvd-muted);font-size:11px;overflow-wrap:anywhere}.status{font-size:11px;line-height:1.5;color:var(--mvd-muted);margin:14px 0}.status.error,.status.success{padding:10px 12px;border-radius:8px;background:var(--mvd-mint)}.status.error{color:var(--mvd-error);background:color-mix(in srgb,var(--mvd-error) 8%,var(--mvd-paper))}.status.success{color:var(--mvd-accent)}
.fields{display:grid;gap:14px;padding-top:3px}.fields>div,.pair>div{min-width:0}.pair{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:12px}label{font-size:11px;font-weight:500;color:var(--mvd-muted);display:block;margin:0 0 6px}select{width:100%;min-width:0;max-width:100%;min-height:37px;border:1px solid var(--mvd-line);border-radius:8px;background:var(--mvd-field);color:var(--mvd-ink);padding:7px 9px;font-size:12px;text-overflow:ellipsis}select:disabled{opacity:.5}select:hover:not(:disabled){border-color:var(--mvd-muted)}.primary{width:100%;min-height:41px;margin-top:20px;border:1px solid var(--mvd-fill);border-radius:8px;background:var(--mvd-fill);color:#fff;padding:10px 12px;font-size:13px;font-weight:600}.primary:hover:not(:disabled){filter:brightness(.94)}.secondary{display:block;width:100%;min-height:36px;border:1px solid var(--mvd-line);border-radius:8px;padding:8px;background:transparent;color:var(--mvd-accent);font-size:12px;margin-top:8px}.secondary:hover{background:var(--mvd-mint)}
.foot{border-top:1px solid var(--mvd-line);padding:11px 20px;display:flex;flex-wrap:wrap;gap:6px 16px;justify-content:space-between;align-items:center;background:var(--mvd-sidebar)}.link{min-height:28px;border:0;border-radius:5px;background:none;color:var(--mvd-muted);padding:4px 0;font-size:10px;text-align:left}.link:hover{color:var(--mvd-accent);text-decoration:underline}.fine{font-size:10px;color:var(--mvd-muted);line-height:1.5;margin:10px 0 0}
@media(prefers-color-scheme:dark){:host{--mvd-ink:#eceef0;--mvd-paper:#1c1d20;--mvd-sidebar:#232529;--mvd-field:#24262b;--mvd-line:#383b42;--mvd-muted:#a2a9b3;--mvd-accent:#5cdda8;--mvd-fill:#008457;--mvd-mint:#203d32;--mvd-hover:#30333a;--mvd-error:#ffaaa2}}
@media(max-width:340px){.pair{grid-template-columns:minmax(0,1fr)}header,.body,.foot{padding-left:16px;padding-right:16px}header span{font-size:10px}.foot{gap:0}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{scroll-behavior:auto!important;transition:none!important;animation:none!important}}
`;  const create = (tag, text, attributes = {}) => { const node = document.createElement(tag); if (text !== undefined) node.textContent = text; for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value); return node; };
  const intersects = (first, second) => first.left < second.right && first.right > second.left && first.top < second.bottom && first.bottom > second.top;
  function triggerPosition(rect, obstacles = [], size = { width: 190, height: 40 }, viewport = { width: innerWidth, height: innerHeight }) {
    const width = size.width, height = size.height;
    const left = Math.max(6, Math.min(viewport.width - width - 6, rect.right - width - 8));
    let top = Math.max(6, rect.top + 8);
    // A scrolled player may be partly behind a sticky header. Put the control
    // below that occupied strip instead of clamping it over the site navigation.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const box = { left, right: left + width, top, bottom: top + height };
      const collisions = obstacles.filter(obstacle => intersects(box, obstacle) && obstacle.bottom + height + 6 < Math.min(rect.bottom, viewport.height));
      if (!collisions.length) break;
      top = Math.max(top, ...collisions.map(obstacle => obstacle.bottom + 6));
    }
    return { left, top: Math.max(6, Math.min(top, viewport.height - height - 6)), placement: "inset" };
  }
  function pageObstacles() {
    const obstacles = [];
    for (const element of [...(document.querySelectorAll?.('header, nav, [role="banner"], [role="navigation"], ytd-masthead, #masthead-container, #chips-wrapper') || [])].slice(0, 40)) {
      if (!element.getBoundingClientRect || element.__mvdOverlayOwned) continue;
      const rect = element.getBoundingClientRect(), style = getComputedStyle(element);
      if (rect.width && rect.height && style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity || 1) > 0) obstacles.push(rect);
    }
    return obstacles;
  }
  function brandMark() {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg"); svg.setAttribute("viewBox", "0 0 64 64"); svg.setAttribute("aria-hidden", "true"); svg.style.width = "23px"; svg.style.height = "23px";
    const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect"); for (const [key, value] of Object.entries({ x: "2", y: "2", width: "60", height: "60", rx: "15", fill: "#16874B" })) rect.setAttribute(key, value);
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path"); for (const [key, value] of Object.entries({ d: "M32 14v26m-10-10 10 10 10-10M17 40v8a3 3 0 0 0 3 3h24a3 3 0 0 0 3-3v-8", fill: "none", stroke: "#FFF", "stroke-width": "4.5", "stroke-linecap": "round", "stroke-linejoin": "round" })) path.setAttribute(key, value);
    svg.append(rect, path); return svg;
  }
  function host() {
    const node = create("div"); node.style.setProperty("all", "initial", "important"); node.style.setProperty("position", "fixed", "important"); node.style.setProperty("z-index", "2147483647", "important"); node.style.setProperty("pointer-events", "none", "important");
    node.__mvdOverlayOwned = true;
    const shadow = node.attachShadow({ mode: "closed" }); const style = create("style", STYLE); shadow.append(style);
    const parent = document.fullscreenElement && document.fullscreenElement.tagName !== "VIDEO" ? document.fullscreenElement : document.documentElement;
    parent.append(node); return { node, shadow };
  }
  function trigger(onOpen, title) {
    const { node, shadow } = host();
    const button = create("button", undefined, { type: "button", "aria-label": `Download this video: ${title}` }); button.append(brandMark(), create("span", "Download this video")); button.className = "trigger"; button.addEventListener("click", event => { event.stopPropagation(); if (event.isTrusted) onOpen(); }); shadow.append(button);
    let size = { width: 190, height: 40 };
    return { node, move(rect) {
      const measured = button.getBoundingClientRect?.(); if (measured?.width && measured?.height) size = { width: Math.ceil(measured.width), height: Math.ceil(measured.height) };
      const position = triggerPosition(rect, pageObstacles(), size);
      node.style.setProperty("left", `${position.left}px`, "important"); node.style.setProperty("top", `${position.top}px`, "important");
    }, setVisible(visible) { node.style.setProperty("display", visible ? "block" : "none", "important"); }, remove() { node.remove(); } };
  }
  function panel({ title, sourceLabel, resolve, enqueue, disable, dismiss, retryPending }) {
    const { node, shadow } = host();
    const shell = create("section", undefined, { role: "dialog", "aria-modal": "true", "aria-label": "MVD download options" }); shell.className = "panel";
    const heading = create("header"); heading.append(brandMark(), create("strong", "MVD"), create("span", "Download options")); const close = create("button", "×", { type: "button", "aria-label": "Close download options" }); heading.append(close);
    const body = create("div"); body.className = "body"; const videoTitle = create("h2", title); const source = create("p", sourceLabel); source.className = "source";
    const message = create("p", "Connecting to MVD and fetching the available formats…", { role: "status", "aria-live": "polite" }); message.className = "status";
    const fields = create("div"); fields.className = "fields"; fields.hidden = true;
    const controls = {};
    function field(key, label, parent = fields) { const wrap = create("div"); const id = `mvd-${key}`; const select = create("select", undefined, { id }); wrap.append(create("label", label, { for: id }), select); parent.append(wrap); controls[key] = select; return wrap; }
    field("mode", "Save"); field("format", "Source format");
    const pair = create("div"); pair.className = "pair"; const qualityWrap = field("quality", "Video quality", pair); const containerWrap = field("container", "Save video as", pair); fields.append(pair);
    const audioPair = create("div"); audioPair.className = "pair"; field("audioFormat", "Audio format", audioPair); field("audioBitrate", "Audio bitrate", audioPair); fields.append(audioPair); audioPair.hidden = true;
    field("folder", "Destination folder");
    const download = create("button", "Download in MVD", { type: "button" }); download.className = "primary"; download.hidden = true;
    const retry = create("button", "Try again", { type: "button" }); retry.className = "secondary"; retry.hidden = true;
    const fine = create("p", "Formats and folders come from the desktop app. Manage custom folders in MVD."); fine.className = "fine";
    const eyebrow = create("p", "Selected video"); eyebrow.className = "eyebrow";
    body.append(eyebrow, videoTitle, source, message, fields, download, retry, fine);
    const foot = create("div"); foot.className = "foot"; const disableButton = create("button", "Disable on this website", { type: "button" }); disableButton.className = "link"; const dismissButton = create("button", "Hide this player button", { type: "button" }); dismissButton.className = "link"; foot.append(disableButton, dismissButton);
    shell.append(heading, body, foot); shadow.append(shell);
    const previousFocus = document.activeElement;
    let disposed = false, preview, token, folders, selectionKey;
    const option = (label, value) => create("option", label, { value });
    const fill = (select, choices) => select.replaceChildren(...choices.map(([label, value]) => option(label, value)));
    function status(text, kind = "") { message.textContent = text; message.className = `status ${kind}`; }
    function selected() { return { mode: controls.mode.value, formatID: controls.format.value || undefined, container: preview.isDirectFile || controls.mode.value === "audioOnly" ? "auto" : controls.container.value, audioFormat: controls.mode.value === "audioOnly" ? controls.audioFormat.value : "original", audioBitrateKbps: controls.mode.value === "audioOnly" && ["m4a", "mp3", "opus"].includes(controls.audioFormat.value) && controls.audioBitrate.value ? Number(controls.audioBitrate.value) : undefined, accelerated: false }; }
    function updateAudioBitrate() { const supportsBitrate = ["m4a", "mp3", "opus"].includes(controls.audioFormat.value); controls.audioBitrate.disabled = !supportsBitrate; if (!supportsBitrate) controls.audioBitrate.value = ""; }
    function updateFormats() {
      const mode = controls.mode.value; const choices = (preview.formats || []).filter(format => mode === "audioOnly" ? format.hasAudio : format.hasVideo);
      fill(controls.format, [["Best available for this mode", ""], ...choices.map(format => [format.label, format.id])]);
      audioPair.hidden = mode !== "audioOnly"; containerWrap.hidden = mode === "audioOnly"; qualityWrap.hidden = mode === "audioOnly";
      controls.quality.disabled = Boolean(controls.format.value);
      if (preview.isDirectFile) { fill(controls.format, [["Original file · source has no alternate formats", ""]]); controls.mode.disabled = true; controls.format.disabled = true; qualityWrap.hidden = true; containerWrap.hidden = true; }
    }
    controls.mode.addEventListener("change", updateFormats); controls.format.addEventListener("change", () => { controls.quality.disabled = Boolean(controls.format.value); }); controls.audioFormat.addEventListener("change", updateAudioBitrate);
    function remove() { if (disposed) return; disposed = true; node.remove(); document.removeEventListener("keydown", keydown, true); previousFocus?.focus?.({ preventScroll: true }); }
    function keydown(event) {
      if (event.key === "Escape") { event.stopPropagation(); remove(); }
      if (event.key === "Tab") {
        const focusable = [...shell.querySelectorAll("button:not(:disabled),select:not(:disabled)")].filter(element => element.getClientRects().length);
        const first = focusable[0], last = focusable.at(-1), current = shadow.activeElement;
        if (event.shiftKey && current === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && current === last) { event.preventDefault(); first?.focus(); }
      }
    }
    document.addEventListener("keydown", keydown, true); close.addEventListener("click", remove); dismissButton.addEventListener("click", () => { dismiss(); remove(); }); disableButton.addEventListener("click", async event => { if (!event.isTrusted) return; disableButton.disabled = true; try { await disable(); remove(); } catch (error) { status(error.message, "error"); disableButton.disabled = false; } });
    async function load() {
      retry.hidden = true; fields.hidden = true; download.hidden = true; status("Fetching the real formats and MVD folders…");
      try {
        const response = await resolve(); if (disposed) return; token = response.sessionToken; preview = response.mediaPreview; folders = response.folders || [];
        if (!preview || !token) throw new Error("The desktop app did not return media information. Update the app and companion together.");
        videoTitle.textContent = preview.title || title;
        fill(controls.mode, [["Video + audio", "videoWithAudio"], ["Video only", "videoOnly"], ["Audio only", "audioOnly"]]);
        fill(controls.quality, (preview.qualities?.length ? preview.qualities : [{ id: "best", label: "Best available" }]).map(quality => [quality.label, quality.id]));
        fill(controls.container, [["Automatic · original codecs", "auto"], ["MP4", "mp4"], ["MKV", "mkv"], ["WebM", "webm"]]);
        fill(controls.audioFormat, [["Original audio", "original"], ["M4A", "m4a"], ["MP3", "mp3"], ["Opus", "opus"], ["FLAC", "flac"], ["WAV", "wav"]]);
        fill(controls.audioBitrate, [["Original / automatic", ""], ["320 kbps", "320"], ["256 kbps", "256"], ["192 kbps", "192"], ["160 kbps", "160"], ["128 kbps", "128"], ["96 kbps", "96"], ["64 kbps", "64"]]); updateAudioBitrate();
        fill(controls.folder, [[response.defaultFolderName || "Default MVD downloads", ""], ...folders.map(folder => [folder.name, folder.id])]);
        updateFormats(); fields.hidden = false; download.hidden = false; status(preview.isDirectFile ? "Original file ready. Choose its destination folder." : `${preview.formats.length} source formats found. Choose what to save.${response.previewTruncated ? " Additional formats are available in MVD." : ""}`); download.disabled = false; download.textContent = "Download in MVD";
      } catch (error) { if (!disposed) { status(error.message || "MVD could not connect. Check that the desktop app and native host are installed.", "error"); retry.hidden = false; } }
    }
    retry.addEventListener("click", event => { if (event.isTrusted) load(); });
    download.addEventListener("click", async event => {
      if (!event.isTrusted || download.disabled) return;
      download.disabled = true; const options = selected(); const quality = (preview.qualities || []).find(item => item.id === controls.quality.value) || { id: "best", label: "Best available" };
      selectionKey = JSON.stringify({ options, quality, folderID: controls.folder.value || undefined });
      status("Waiting for MVD to confirm this download…");
      try {
        const result = await enqueue({ sessionToken: token, options, quality, folderID: controls.folder.value || undefined }); if (disposed) return;
        if (!result.jobID || !result.accepted) throw new Error("No durable job confirmation was returned.");
        status(`Download started in MVD · job ${result.jobID.slice(0, 8)}. You can close this panel.`, "success"); download.textContent = "Added to downloads"; for (const control of Object.values(controls)) control.disabled = true;
      } catch (error) { if (!disposed) { status(error.message || "Download not confirmed. Retry preserves its request key.", "error"); download.disabled = false; download.textContent = "Retry download"; } }
    });
    close.focus({ preventScroll: true }); load();
    return { remove };
  }
  globalThis.__MVDOverlayUI = Object.freeze({ trigger, panel, triggerPosition });
})();
