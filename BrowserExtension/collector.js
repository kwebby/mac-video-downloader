(() => {
  if (globalThis.__harborMediaObserver) return globalThis.__harborMediaObserver.snapshot();
  const playerIDs = new WeakMap(), encryptedPlayers = new WeakSet(), triggers = new Map();
  let dismissed = new WeakSet(), nextPlayerID = 1, timer, lastPageURL = location.href, lastPayload = "", disabled = null, activePanel = null;
  const context = globalThis.__MVDPlayerContext;
  const text = value => String(value || "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 160);
  const meta = name => document.querySelector(`meta[property="${name}"], meta[name="${name}"]`)?.content || "";
  function isVisibleMedia(element) {
    try { return Boolean(context?.visiblePlaying(element, element.getBoundingClientRect(), getComputedStyle(element))); }
    catch { return false; }
  }
  function allMedia(preferredPlayer = null) {
    const media = [...document.querySelectorAll("video, audio")].slice(0, 1000);
    // Reel feeds keep many hidden players ahead of the current one in DOM order.
    // Keep the clicked element and visible media before applying collection limits.
    if (preferredPlayer?.isConnected && !media.includes(preferredPlayer)) media.unshift(preferredPlayer);
    return media.filter(element => !context?.isAd(element))
      .map((element, index) => ({ element, index, priority: element === preferredPlayer ? 2 : isVisibleMedia(element) ? 1 : 0 }))
      .sort((a, b) => b.priority - a.priority || a.index - b.index).slice(0, 80).map(item => item.element);
  }
  function playerMetadata(element, count, pageTitle, pageImage, sources = null, posterURL = null) {
    if (!playerIDs.has(element)) playerIDs.set(element, `dom-player-${nextPlayerID++}`);
    const explicit = element.getAttribute("aria-label") || element.title;
    const caption = element.closest("figure")?.querySelector("figcaption")?.textContent;
    const poster = posterURL || context?.posterFor?.(element, location.href) || element.poster;
    return { assetID: playerIDs.get(element), title: text(explicit || caption || pageTitle), titleSource: explicit ? "Video title" : caption ? "Nearby caption" : "Page title fallback", thumbnailURL: String(poster || pageImage || "").slice(0, 8193), thumbnailSource: element.poster ? "Video poster" : poster ? "Nearby player poster" : pageImage ? "Page image fallback" : "No thumbnail exposed", kind: "media", protected: encryptedPlayers.has(element) || Boolean(element.mediaKeys), targetURL: context?.targetFor(element, location.href, count, sources) || null, ad: Boolean(context?.isAd(element)), playing: !element.paused && !element.ended };
  }
  function snapshot(preferredPlayer = null) {
    const observations = [], players = [], media = allMedia(preferredPlayer), resources = performance.getEntriesByType("resource").slice(-240);
    let inaccessibleMedia = 0, protectedMedia = 0, observationCharacters = 0;
    const pageTitle = text(meta("og:title") || document.title), pageImage = String(meta("og:image") || meta("twitter:image") || "").slice(0, 8193);
    function add(url, metadata) {
      if (observations.length >= 400 || !url || /^(?:blob|data):/.test(String(url))) return;
      const bounded = String(url).slice(0, 8193); if (observationCharacters + bounded.length > 100 * 1024) return;
      observationCharacters += bounded.length; observations.push({ url: bounded, ...metadata });
    }
    for (const element of media) {
      const poster = context?.posterFor?.(element, location.href) || element.poster || null;
      const sources = context?.sourceEvidenceFor?.(element, location.href, resources, poster) || [];
      const metadata = playerMetadata(element, media.length, pageTitle, pageImage, sources, poster);
      if (metadata.protected) protectedMedia += 1;
      if (String(element.currentSrc || element.src || "").startsWith("blob:") && !sources.length) inaccessibleMedia += 1;
      players.push(metadata); add(element.currentSrc || element.src, metadata);
      for (const source of [...element.querySelectorAll("source[src]")].slice(0, 8)) add(source.src, { ...metadata, mime: String(source.type || "").slice(0, 120) });
      for (const source of sources) add(source.url, { ...metadata, mime: source.mime, sourceEvidence: source.evidence });
      if (metadata.targetURL && !metadata.protected && context?.providerURL(metadata.targetURL)) add(metadata.targetURL, metadata);
    }
    for (const anchor of [...document.querySelectorAll("a[href]")].slice(0, 220)) add(anchor.href, { title: text(anchor.textContent || anchor.title), titleSource: "Link title", kind: "file" });
    for (const entry of resources.slice(-100)) add(entry.name, { kind: "resource", requestType: "other" });
    const frameOrigins = [...document.querySelectorAll("iframe[src]")].slice(0, 32).filter(frame => {
      if (!frame.getBoundingClientRect) return false;
      const rect = frame.getBoundingClientRect();
      if (rect.width < 140 || rect.height < 80 || rect.right <= 0 || rect.bottom <= 0 || rect.left >= innerWidth || rect.top >= innerHeight) return false;
      const style = getComputedStyle(frame);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity || 1) === 0) return false;
      try {
        const url = new URL(frame.src);
        if (/^(?:accounts|login|auth)\./i.test(url.hostname) || /\/(?:signin|oauth|login|authorize)(?:[/?#]|$)/i.test(url.pathname)) return false;
        return Boolean(context?.providerURL(frame.src) || frame.allowFullscreen || frame.hasAttribute?.("allowfullscreen") || /(?:player|embed|video)/i.test(url.pathname) || /(?:autoplay|fullscreen)/i.test(frame.allow || ""));
      } catch { return false; }
    }).map(frame => new URL(frame.src).origin).slice(0, 12);
    const data = { pageURL: location.href, title: pageTitle, pageImage, observations, players, frameOrigins, inaccessibleMedia, protectedMedia, disabled: disabled === true };
    const oversized = () => JSON.stringify(data).length > 220 * 1024;
    // Decorative signed poster URLs can dwarf the player identities. Drop those
    // before sources, and retain IDs even when unselected source URLs exceed budget.
    if (oversized()) {
      data.pageImage = "";
      for (const item of [...data.players, ...data.observations]) { item.thumbnailURL = ""; item.thumbnailSource = "No thumbnail exposed"; }
    }
    while (oversized() && data.observations.length) data.observations.pop();
    for (let index = data.players.length - 1; index >= 0 && oversized(); index -= 1) data.players[index].targetURL = null;
    return data;
  }
  async function publish(force = false) {
    const data = snapshot(), serialized = JSON.stringify(data);
    if (!force && serialized === lastPayload) return;
    lastPayload = serialized;
    const result = await chrome.runtime.sendMessage({ type: "mediaObserved", snapshot: data });
    if (force && result?.ok === false) throw new Error(result.error || "Player details changed. Reopen this video's download button.");
    return result;
  }
  async function request(type, extra = {}) {
    const result = await chrome.runtime.sendMessage({ type, pageURL: location.href, ...extra });
    if (!result?.ok) throw new Error(result?.error || "MVD could not complete this action. Open the companion and check the desktop connection.");
    return result;
  }
  function removeAll() { for (const trigger of triggers.values()) trigger.remove(); triggers.clear(); activePanel?.remove(); activePanel = null; }
  async function openPanel(video) {
    if (disabled || !globalThis.__MVDOverlayUI) return;
    activePanel?.remove(); const data = snapshot(video), playerID = playerIDs.get(video), player = data.players.find(item => item.assetID === playerID);
    if (!player || player.protected || context?.isAd(video)) return;
    const pageAtOpen = location.href;
    activePanel = globalThis.__MVDOverlayUI.panel({ title: player.title, sourceLabel: new URL(location.href).hostname,
      resolve: async () => { if (location.href !== pageAtOpen) throw new Error("The page changed. Open the video button again."); return request("panelResolve", { playerID, snapshot: snapshot(video) }); },
      enqueue: async payload => { if (location.href !== pageAtOpen) throw new Error("The page changed. Open the video button again."); return request("panelEnqueue", { playerID, ...payload, snapshot: snapshot(video) }); },
      disable: async () => { await request("disableSite", { disabled: true }); disabled = true; removeAll(); },
      dismiss: () => { dismissed.add(video); triggers.get(video)?.remove(); triggers.delete(video); }
    });
  }
  function position() {
    for (const [video, trigger] of triggers) {
      if (!video.isConnected || disabled || context?.isAd(video) || encryptedPlayers.has(video)) { trigger.remove(); triggers.delete(video); continue; }
      const rect = video.getBoundingClientRect(); const visible = context.visiblePlaying(video, rect, getComputedStyle(video)); trigger.setVisible(visible); if (visible) trigger.move(rect);
    }
  }
  function refreshOverlays() {
    if (!context || !globalThis.__MVDOverlayUI || disabled !== false) return;
    for (const video of allMedia().filter(element => element.tagName === "VIDEO").slice(0, 40)) {
      if (!video.isConnected || dismissed.has(video) || encryptedPlayers.has(video) || context.isAd(video) || video.mediaKeys) continue;
      const visible = context.visiblePlaying(video, video.getBoundingClientRect(), getComputedStyle(video));
      if (visible && !triggers.has(video)) triggers.set(video, globalThis.__MVDOverlayUI.trigger(() => openPanel(video), playerMetadata(video, allMedia().length, document.title, "").title));
    }
    position();
  }
  function schedule() { clearTimeout(timer); timer = setTimeout(() => { refreshOverlays(); publish().catch(() => {}); }, 250); }
  const observer = new MutationObserver(records => { if (records?.length && records.every(record => record.target?.__mvdOverlayOwned || (record.type === "childList" && [...record.addedNodes, ...record.removedNodes].length && [...record.addedNodes, ...record.removedNodes].every(node => node.__mvdOverlayOwned)))) return; schedule(); });
  observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["src", "poster", "title", "aria-label", "content", "class", "style"] });
  for (const name of ["loadedmetadata", "loadstart", "emptied", "play", "playing", "pause", "ended"]) document.addEventListener(name, schedule, true);
  document.addEventListener("encrypted", event => { if (event.target instanceof HTMLMediaElement) encryptedPlayers.add(event.target); schedule(); }, true);
  for (const name of ["popstate", "hashchange", "pageshow", "yt-navigate-finish", "yt-page-data-updated", "yt-player-updated"]) window.addEventListener(name, schedule);
  window.addEventListener("scroll", position, true); window.addEventListener("resize", position);
  document.addEventListener("fullscreenchange", () => { removeAll(); schedule(); });
  setInterval(() => { if (location.href !== lastPageURL) { lastPageURL = location.href; lastPayload = ""; dismissed = new WeakSet(); removeAll(); request("overlayState").then(result => { disabled = result.disabled; schedule(); }).catch(() => {}); } else position(); }, 1000);
  try { new PerformanceObserver(schedule).observe({ type: "resource", buffered: true }); } catch { /* DOM events remain available. */ }
  chrome.runtime.onMessage?.addListener((message, sender, sendResponse) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message?.type === "siteState") { disabled = message.disabled; if (disabled) removeAll(); else schedule(); }
    if (message?.type === "showPlayerPanel" && disabled === false) {
      const media = allMedia(); const video = media.find(element => message.playerID && playerIDs.get(element) === message.playerID) || media.find(element => !element.paused && !element.ended) || media[0];
      if (video) openPanel(video).then(() => sendResponse({ opened: true })).catch(error => sendResponse({ error: error.message }));
      else sendResponse({ error: "Play a video on this page, then click its MVD download button." });
      return true;
    }
  });
  globalThis.__harborMediaObserver = { snapshot };
  request("overlayState").then(result => { disabled = result.disabled === true; if (!disabled) refreshOverlays(); }).catch(() => { disabled = false; refreshOverlays(); });
  schedule(); return snapshot();
})();
