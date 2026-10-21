(() => {
  if (globalThis.__MVDPlayerContext) return;
  const permalinkOwners = new WeakMap();
  function publicHTTP(raw, base) {
    if (typeof raw !== "string" || !raw.trim()) return null;
    try { const url = new URL(raw, base); return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password ? url.href : null; } catch { return null; }
  }
  function providerURL(raw) {
    const input = publicHTTP(raw);
    if (!input) return null;
    const url = new URL(input);
    const host = url.hostname.toLowerCase();
    if (host === "youtu.be" || /(^|\.)youtube(?:-nocookie)?\.com$/.test(host)) {
      const parts = url.pathname.split("/").filter(Boolean);
      const id = host === "youtu.be" ? parts[0] : url.searchParams.get("v") || (["embed", "shorts", "live"].includes(parts[0]) ? parts[1] : null);
      return id && /^[\w-]{6,64}$/.test(id) ? `https://www.youtube.com/watch?v=${encodeURIComponent(id)}` : null;
    }
    if (/(^|\.)vimeo\.com$/.test(host) && /\d{4,}/.test(url.pathname)) return input;
    if (/(^|\.)instagram\.com$/.test(host) && /^\/(?:reels?|p|tv)\/[A-Za-z0-9_-]{5,}\/?$/.test(url.pathname)) return input;
    if (/(^|\.)(?:x|twitter)\.com$/.test(host) && /^\/(?:[^/]+\/status|i\/web\/status)\/\d+(?:\/video\/\d+)?\/?$/.test(url.pathname)) return input;
    if (/(^|\.)facebook\.com$/.test(host) && (/^\/(?:reel|(?:[^/]+\/)?videos)\/\d+\/?$/.test(url.pathname) || (url.pathname === "/watch/" && /^\d+$/.test(url.searchParams.get("v") || "")))) return input;
    if (/(^|\.)tiktok\.com$/.test(host) && /^\/@[^/]+\/video\/\d+\/?$/.test(url.pathname)) return input;
    if (/(^|\.)linkedin\.com$/.test(host) && (/^\/posts\/[^/?#]+-\d+-[\w-]{4}\/?$/.test(url.pathname) || /^\/feed\/update\/urn:li:activity:\d+\/?$/.test(url.pathname))) return input;
    return null;
  }
  function isSegment(raw) { try { const path = new URL(raw).pathname; return /\.(?:ts|m4s|cmfv|cmfa)$/i.test(path) || /(?:^|\/)(?:init|segment\d*|seg\d+|chunk\d+|frag(?:ment)?\d+)(?:[-_.\/]|$)/i.test(path) || (/\/(?:playlist\/vid|dms\/video)\//i.test(path) && /\/(?:dash|hls)[^/]*(?:\/|$)/i.test(path) && !/\.(?:mpd|m3u8)$/i.test(path)); } catch { return true; } }
  function isAd(video) { return Boolean(video.closest?.(".ad-showing, .ad-interrupting, [data-ad-slot], [data-ad-video], .video-ads, .ima-ad-container")); }
  function providerFamily(raw) {
    try { const host = new URL(raw).hostname.toLowerCase(); return ["instagram.com", "facebook.com", "tiktok.com", "youtube.com", "youtube-nocookie.com", "youtu.be", "vimeo.com", "x.com", "twitter.com", "linkedin.com"].find(domain => host === domain || host.endsWith("." + domain)) || null; } catch { return null; }
  }
  function linkedInAsset(raw) {
    if (typeof raw !== "string" || raw.length > 8192) return null;
    const urn = raw.match(/^urn:li:(?:digitalmediaAsset|video|videoPlayMetadata):([A-Za-z0-9_-]{12,128})$/);
    if (urn) return urn[1];
    try {
      const url = new URL(raw);
      if (!/(^|\.)licdn\.com$/.test(url.hostname)) return null;
      return url.pathname.match(/\/(?:dms\/(?:image|video)|playlist\/vid)\/(?:v\d+\/)?([A-Za-z0-9_-]{12,128})(?:\/|$)/)?.[1] || null;
    } catch { return null; }
  }
  function mediaMime(raw, mime = "") {
    const value = String(mime).split(";")[0].trim().toLowerCase();
    if (/^(?:video|audio)\/iso\.segment$/.test(value)) return null;
    if (/^(?:video|audio)\//.test(value) || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "application/dash+xml"].includes(value)) return value;
    try {
      const url = new URL(raw), path = url.pathname;
      if (/\.(?:m3u8)$/i.test(path)) return "application/vnd.apple.mpegurl";
      if (/\.mpd$/i.test(path)) return "application/dash+xml";
      if (/\.(?:mp4|m4v|mov)$/i.test(path)) return "video/mp4";
      if (/\.(?:webm|mkv|ogv)$/i.test(path)) return "video/" + path.split(".").pop().toLowerCase();
      if (/(^|\.)licdn\.com$/.test(url.hostname) && /\/(?:playlist\/vid|dms\/video)\/(?:v\d+\/)?[A-Za-z0-9_-]{12,128}\/mp4-[^/]+\//i.test(path)) return "video/mp4";
    } catch { /* A source must be a full HTTP URL before MIME inference. */ }
    return null;
  }
  function posterFor(video, pageURL) {
    function safe(raw) { const url = publicHTTP(raw, pageURL); return url && url.length <= 8192 ? url : null; }
    const explicit = safe(video.poster || video.getAttribute?.("poster"));
    if (explicit) return explicit;
    let container = video.parentElement;
    for (let depth = 0; container && depth < 5; depth += 1, container = container.parentElement) {
      const videos = [...(container.querySelectorAll?.("video") || [])];
      if (videos.length !== 1 || videos[0] !== video) break;
      const playerRoot = container.hasAttribute?.("data-vjs-player") || /(?:^|\s)(?:video-js|video-player|html5-video-player|plyr|jwplayer)(?:\s|$)/.test(String(container.className || ""));
      const nodes = [...(container.querySelectorAll?.(".vjs-poster, [data-poster], [data-video-poster], [style*=\"background-image\"]") || [])].slice(0, 24);
      if (playerRoot) nodes.push(...[...(container.querySelectorAll?.("img") || [])].slice(0, 8));
      for (const node of nodes) {
        const poster = safe(node.getAttribute?.("data-poster") || node.getAttribute?.("data-video-poster") || (node.tagName === "IMG" ? node.currentSrc || node.src : ""));
        if (poster) return poster;
        try {
          const style = node.style?.backgroundImage || node.ownerDocument?.defaultView?.getComputedStyle?.(node)?.backgroundImage || (typeof getComputedStyle === "function" ? getComputedStyle(node).backgroundImage : "");
          // A single CSS background URL is data. Do not evaluate styles/scripts,
          // and do not guess among layered images or a broad feed container.
          const match = String(style || "").match(/^url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)$/i);
          const background = match && safe((match[1] ?? match[2] ?? match[3]).trim());
          if (background) return background;
        } catch { /* A missing/departing poster must not break player discovery. */ }
      }
      if (playerRoot) break;
    }
    return null;
  }
  function sourceEvidenceFor(video, pageURL, resources = [], posterURL = null) {
    if (isAd(video) || video.mediaKeys) return [];
    const sources = [], playerAssets = new Set();
    function asset(raw) { const id = linkedInAsset(raw); if (id) playerAssets.add(id); }
    function add(raw, mime, evidence, rank = 0, explicit = false) {
      const url = publicHTTP(raw, pageURL);
      if (!url || url.length > 8192 || isSegment(url) || /\.(?:png|jpe?g|webp|avif|gif|svg|vtt|srt)$/i.test(new URL(url).pathname)) return;
      const type = mediaMime(url, mime);
      if ((!type && !explicit) || /^(?:video|audio)\/iso\.segment$/i.test(String(mime).split(";")[0])) return;
      const existing = sources.find(source => source.url === url);
      if (!existing && sources.length < 24) sources.push({ url, mime: type || "", evidence, rank: Number(rank) || 0 });
    }
    asset(posterURL || posterFor(video, pageURL)); asset(video.currentSrc); asset(video.src);
    add(video.currentSrc, "", "Player source", 0, true); add(video.src, "", "Player source", 0, true);
    for (const source of [...(video.querySelectorAll?.("source[src]") || [])].slice(0, 12)) { asset(source.src); add(source.src, source.type, "Player source", 0, true); }
    const sourceAttributes = ["data-sources", "data-source", "data-src", "data-video-src", "data-video-url", "data-hls", "data-dash", "data-streaming-url", "data-player-config", "data-setup"];
    const identityAttributes = ["data-media-urn", "data-video-urn", "data-urn", "data-video-id", "data-media-id"];
    let nodes = 0;
    function readConfig(value, depth = 0) {
      if (!value || depth > 7 || ++nodes > 320) return;
      if (Array.isArray(value)) { for (const item of value.slice(0, 32)) readConfig(item, depth + 1); return; }
      if (typeof value !== "object") return;
      const mime = value.type || value.mime || value.mimeType || value.mediaType || "";
      const rank = Number(value.height || value["data-bitrate"] || value.bitrate || value.bitRate) || 0;
      for (const key of ["src", "url", "file", "streamingUrl", "progressiveUrl"]) if (typeof value[key] === "string") { asset(value[key]); add(value[key], mime, "Player configuration", rank); }
      for (const [key, item] of Object.entries(value).slice(0, 40)) if (typeof item === "object" && /^(?:sources|streams|progressiveStreams|adaptiveStreams|streamingLocations|masterPlaylists|formats|source|video|player|playback|data)$/i.test(key)) readConfig(item, depth + 1);
    }
    let container = video;
    for (let depth = 0; container && depth < 6; depth += 1, container = container.parentElement) {
      if (container !== video && [...(container.querySelectorAll?.("video") || [])].length > 1) break;
      for (const name of identityAttributes) asset(container.getAttribute?.(name));
      for (const name of sourceAttributes) {
        const raw = container.getAttribute?.(name);
        if (typeof raw !== "string" || !raw || raw.length > 96 * 1024) continue;
        if (/^[\s]*[\[{]/.test(raw)) { try { readConfig(JSON.parse(raw)); } catch { /* Read data only; never run player scripts. */ } continue; }
        const direct = publicHTTP(raw, pageURL);
        if (direct) { asset(direct); add(direct, "", "Player configuration"); continue; }
      }
    }
    // Resource timing alone does not identify a player. LinkedIn's explicit
    // poster/URN/config asset ID must match a known progressive or manifest URL.
    if (playerAssets.size) for (const entry of (Array.isArray(resources) ? resources : []).slice(-240)) {
      const raw = typeof entry === "string" ? entry : entry?.name;
      const id = linkedInAsset(raw);
      if (id && playerAssets.has(id)) add(raw, "", "Matching player asset");
    }
    return sources.sort((a, b) => Number(/mpegurl|dash\+xml/.test(b.mime)) - Number(/mpegurl|dash\+xml/.test(a.mime)) || b.rank - a.rank).map(({ rank, ...source }) => source);
  }
  function permalinkIdentity(raw) {
    const url = new URL(raw);
    const family = providerFamily(raw);
    const path = url.pathname.replace(/^\/reels\//, "/reel/").replace(/\/$/, "");
    return `${family === "twitter.com" ? "x.com" : family}${path}${["/watch", "/watch/"].includes(url.pathname) ? `?v=${url.searchParams.get("v")}` : ""}`;
  }
  function visibleArea(video) {
    if (!video.getBoundingClientRect || video.isConnected === false || video.readyState < 1 || isAd(video) || video.mediaKeys) return 0;
    try {
      const rect = video.getBoundingClientRect();
      const style = video.ownerDocument?.defaultView?.getComputedStyle?.(video) || (typeof getComputedStyle === "function" ? getComputedStyle(video) : null);
      if (style && (style.display === "none" || style.visibility === "hidden" || Number(style.opacity || 1) === 0)) return 0;
      const width = Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left));
      const height = Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top));
      return width >= 140 && height >= 80 ? width * height : 0;
    } catch { return 0; }
  }
  function isFocusedPlayer(video, playerCount) {
    const document = video.ownerDocument;
    if (!document?.querySelectorAll || !video.getBoundingClientRect) return playerCount === 1;
    const elements = [...document.querySelectorAll("video")];
    const visible = [video, ...elements.filter(element => element !== video)].slice(0, 80).map(element => ({ element, area: visibleArea(element) })).filter(item => item.area > 0).sort((first, second) => second.area - first.area);
    if (!visible.length || visible[0].element !== video) return false;
    // Reel feeds preload many siblings. A sole/dominant visible player can own
    // the current permalink; two similarly visible cards need their own links.
    return visible.length === 1 || visible[0].area >= visible[1].area * 1.5;
  }
  function nearbyPermalink(video, pageURL) {
    const family = providerFamily(pageURL);
    if (!family) return null;
    let container = video.parentElement;
    for (let depth = 0; container && depth < 8; depth += 1, container = container.parentElement) {
      const videos = [...(container.querySelectorAll?.("video") || [])];
      if (videos.length > 1) break;
      const links = [...(container.querySelectorAll?.("a[href]") || [])].slice(0, 40);
      const matches = new Map();
      for (const link of links) {
        const url = providerURL(publicHTTP(link.href, pageURL));
        if (!url || providerFamily(url) !== family) continue;
        const identity = permalinkIdentity(url);
        if (!matches.has(identity)) matches.set(identity, url);
      }
      if (matches.size === 1) return [...matches.values()][0];
      if (matches.size > 1) return null;
    }
    return null;
  }
  function ownsCurrentPermalink(video, ownProvider, associated, focused) {
    if (!focused) return false;
    const document = video.ownerDocument;
    if (!document) return true;
    const identity = permalinkIdentity(ownProvider), source = video.currentSrc || video.src || "";
    let ownership = permalinkOwners.get(document);
    if (!ownership || ownership.identity !== identity) {
      ownership = { identity, video, source, changed: false };
      permalinkOwners.set(document, ownership);
    }
    // A reel may become visible before pushState updates its permalink. Never
    // lend the previous reel's page URL to that sibling (or a recycled source).
    if (ownership.video !== video || ownership.source !== source) ownership.changed = true;
    if (associated) {
      if (permalinkIdentity(associated) === identity) {
        ownership.video = video; ownership.source = source; ownership.changed = false;
      } else ownership.changed = true;
    }
    return !ownership.changed && ownership.video === video;
  }
  function targetFor(video, pageURL, playerCount, sources = null) {
    if (isAd(video) || video.mediaKeys) return null;
    const exposed = sources || sourceEvidenceFor(video, pageURL);
    // A logged-in feed is not a supported video page. Use only sources bound
    // to this player, or its explicit individual post permalink below.
    if (providerFamily(pageURL) === "linkedin.com" && exposed.length) return exposed[0].url;
    const card = video.closest?.("ytd-rich-item-renderer, ytd-video-renderer, ytd-reel-video-renderer, ytd-grid-video-renderer, ytm-rich-item-renderer");
    const cardLink = card?.querySelector?.('a[href*="/watch?v="], a[href*="/shorts/"], a[href*="youtu.be/"]');
    const cardTarget = providerURL(cardLink?.href);
    if (cardTarget) return cardTarget;
    const associated = nearbyPermalink(video, pageURL);
    const ownProvider = providerURL(pageURL);
    const focused = isFocusedPlayer(video, playerCount);
    const ownsPage = ownProvider && ownsCurrentPermalink(video, ownProvider, associated, focused);
    if (associated) return associated;
    if (ownProvider && (ownsPage || (!video.ownerDocument && /(?:youtube|youtu\.be|vimeo)/.test(new URL(ownProvider).hostname)))) return ownProvider;
    if (exposed.length) return exposed[0].url;
    // A social feed URL without a post/reel ID is not the video's permalink.
    if (providerFamily(pageURL)) return null;
    return focused ? publicHTTP(pageURL) : null;
  }
  function visiblePlaying(video, rect, style) {
    return video.readyState >= 1 && !isAd(video) && !video.mediaKeys && rect.width >= 140 && rect.height >= 80 && rect.right > 0 && rect.bottom > 0 && rect.left < innerWidth && rect.top < innerHeight && style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity || 1) > 0;
  }
  globalThis.__MVDPlayerContext = Object.freeze({ publicHTTP, providerURL, targetFor, posterFor, sourceEvidenceFor, visiblePlaying, isAd, isFocusedPlayer });
})();
