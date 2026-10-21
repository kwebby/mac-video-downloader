export const MAX_URL_LENGTH = 8192;
export const MAX_CANDIDATES = 80;
export const MAX_VARIANTS = 8;
const DIRECT_EXTENSIONS = new Set(["mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "zip", "gz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "pdf", "epub", "csv", "json", "txt", "exe", "msi", "deb", "rpm"]);
const MEDIA_EXTENSIONS = new Set(["mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "aac", "flac", "wav", "ogg", "ogv", "opus", "m3u8", "mpd"]);
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico"]);
const MANIFEST_MIMES = new Set(["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl", "application/dash+xml"]);

function isSubdomain(host, domain) { return host === domain || host.endsWith(`.${domain}`); }
export function cleanText(value, limit = 160) { return typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, limit) : ""; }
function extension(url) { return new URL(url).pathname.split(".").pop().toLowerCase(); }

// Fast browser-side screening; the native host additionally resolves and screens DNS.
export function validatePublicURL(raw) {
  if (typeof raw !== "string" || !raw || raw.length > MAX_URL_LENGTH) throw new Error("Choose a valid HTTP or HTTPS URL.");
  let url;
  try { url = new URL(raw); } catch { throw new Error("Choose a valid HTTP or HTTPS URL."); }
  if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password) throw new Error("Only public HTTP and HTTPS URLs without embedded credentials are supported.");
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host.includes(".") || /(?:^|\.)(?:localhost|local|internal|test|invalid|example)$/.test(host) || host.endsWith(".home.arpa")) throw new Error("Private and local network URLs are unavailable in the companion.");
  if (host.startsWith("[") || /^\d+\.\d+\.\d+\.\d+$/.test(host)) {
    if (host.startsWith("[")) throw new Error("Literal IPv6 addresses are unavailable in the companion. Use a public hostname.");
    const [a, b, c] = host.split(".").map(Number);
    if (a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && (b === 168 || b === 0 || (b === 88 && c === 99))) || (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) || (a === 203 && b === 0 && c === 113)) throw new Error("Private and reserved network URLs are unavailable in the companion.");
  }
  return url.href;
}

export function safeThumbnail(raw, pageURL) {
  try { return raw ? validatePublicURL(new URL(raw, pageURL).href) : null; } catch { return null; }
}
export function originPattern(raw) { return `${new URL(validatePublicURL(raw)).origin}/*`; }
export function isDirectDownloadURL(raw) { try { return DIRECT_EXTENSIONS.has(extension(raw)); } catch { return false; } }
export function isSegmentURL(raw) {
  try {
    const path = new URL(raw).pathname;
    return /\.(?:ts|m4s|cmfv|cmfa)(?:$)/i.test(path) || /(?:^|\/)(?:init|segment\d*|seg\d+|chunk\d+|frag(?:ment)?\d+)(?:[-_.\/]|$)/i.test(path) || (/\/(?:playlist\/vid|dms\/video)\//i.test(path) && /\/(?:dash|hls)[^/]*(?:\/|$)/i.test(path) && !/\.(?:mpd|m3u8)$/i.test(path));
  } catch { return true; }
}
export function mediaType(raw, mime = "") {
  const normalized = cleanText(mime, 120).split(";")[0].toLowerCase();
  const ext = extension(raw);
  if (ext === "m3u8" || (MANIFEST_MIMES.has(normalized) && normalized !== "application/dash+xml")) return "HLS";
  if (ext === "mpd" || normalized === "application/dash+xml") return "DASH";
  if (MEDIA_EXTENSIONS.has(ext)) return ext.toUpperCase();
  if (normalized.startsWith("video/")) return normalized.slice(6).toUpperCase();
  if (normalized.startsWith("audio/")) return `Audio · ${normalized.slice(6).toUpperCase()}`;
  return "Media";
}
export function isNetworkMedia(raw, mime = "", requestType = "") {
  try {
    const url = validatePublicURL(raw);
    if (isSegmentURL(url) || IMAGE_EXTENSIONS.has(extension(url)) || !["media", "xmlhttprequest", "other"].includes(requestType)) return false;
    const normalized = cleanText(mime, 120).split(";")[0].toLowerCase();
    if (normalized.includes("html") || normalized.startsWith("image/") || /^(?:video|audio)\/iso\.segment$/.test(normalized)) return false;
    return MEDIA_EXTENSIONS.has(extension(url)) || MANIFEST_MIMES.has(normalized) || normalized.startsWith("video/") || normalized.startsWith("audio/");
  } catch { return false; }
}

export function collectCandidates(observations, pageURL, metadata = {}) {
  validatePublicURL(pageURL);
  const candidates = [];
  for (const observation of Array.isArray(observations) ? observations.slice(0, 400) : []) {
    if (!observation || typeof observation.url !== "string") continue;
    try {
      const url = validatePublicURL(new URL(observation.url, pageURL).href);
      const ext = extension(url);
      const normalizedMime = cleanText(observation.mime, 120).split(";")[0].toLowerCase();
      if (isSegmentURL(url) || IMAGE_EXTENSIONS.has(ext) || /^(?:video|audio)\/iso\.segment$/.test(normalizedMime)) continue;
      const isMedia = observation.kind === "media" || MEDIA_EXTENSIONS.has(ext) || isNetworkMedia(url, observation.mime, observation.requestType || "other");
      if (!isMedia && !isDirectDownloadURL(url)) continue;
      const parsed = new URL(url);
      const pageTitle = cleanText(metadata.pageTitle || metadata.title) || parsed.hostname;
      const suppliedTitle = cleanText(observation.title);
      let basename;
      try { basename = decodeURIComponent(parsed.pathname.split("/").pop()); } catch { basename = parsed.pathname.split("/").pop(); }
      const title = suppliedTitle || (observation.kind === "network" ? pageTitle : cleanText(basename)) || pageTitle;
      const assetID = cleanText(observation.assetID, 80);
      const thumbnailURL = safeThumbnail(observation.thumbnailURL || metadata.pageImage, pageURL);
      const candidate = {
        id: assetID || url, assetID: assetID || null, url, title,
        titleSource: cleanText(observation.titleSource, 40) || (suppliedTitle ? "Source title" : observation.kind === "network" ? "Page title fallback" : "Filename fallback"),
        pageTitle, thumbnailURL,
        thumbnailSource: thumbnailURL ? cleanText(observation.thumbnailSource, 40) || (observation.thumbnailURL ? "Video poster" : "Page image fallback") : "No thumbnail exposed",
        mediaType: mediaType(url, observation.mime), kind: isMedia ? "media" : "file", isMedia,
        downloadable: isDirectDownloadURL(url), reviewable: isMedia, protected: observation.protected === true,
        discovery: observation.kind === "network" ? "Network metadata" : "Page DOM",
        sourceLabel: `${parsed.hostname}${parsed.pathname === "/" ? "" : ` · ${cleanText(basename, 65)}`}`,
        // Some CDNs expose complete media at extensionless URLs. Preserve the
        // observed type so selected-player fallback can verify those sources
        // without treating every opaque player/page URL as downloadable media.
        variants: [{ url, mediaType: mediaType(url, observation.mime), ...(normalizedMime && isNetworkMedia(url, normalizedMime, "other") ? { mime: normalizedMime } : {}) }]
      };
      const existing = candidates.find(item => item.url === url || (assetID && item.assetID === assetID));
      if (existing) mergeCandidate(existing, candidate);
      else candidates.push(candidate);
      if (candidates.length === MAX_CANDIDATES) break;
    } catch { /* Rejected resources do not become available sources. */ }
  }
  return candidates;
}

export function mergeCandidate(target, incoming) {
  const variants = [...(target.variants || []), ...(incoming.variants || [{ url: incoming.url, mediaType: incoming.mediaType }])];
  const unique = [];
  for (const variant of variants) {
    const existing = unique.find(item => item.url === variant.url);
    if (!existing) unique.push({ ...variant });
    else if (!existing.mime && variant.mime) existing.mime = variant.mime;
  }
  target.variants = unique.slice(0, MAX_VARIANTS);
  if (!target.thumbnailURL && incoming.thumbnailURL) { target.thumbnailURL = incoming.thumbnailURL; target.thumbnailSource = incoming.thumbnailSource; }
  if (target.titleSource?.includes("fallback") && !incoming.titleSource?.includes("fallback")) { target.title = incoming.title; target.titleSource = incoming.titleSource; }
  target.protected ||= incoming.protected;
  if (incoming.discovery !== target.discovery) target.discovery = "DOM + network metadata";
  return target;
}

export function mergePageCandidates(dom, network, page = {}) {
  const result = structuredClone(Array.isArray(dom) ? dom.slice(0, MAX_CANDIDATES) : []);
  for (const source of Array.isArray(network) ? network.slice(0, MAX_CANDIDATES) : []) {
    let existing = result.find(item => item.variants.some(variant => variant.url === source.url));
    if (!existing && page.players?.length === 1 && source.isMedia) existing = result.find(item => item.assetID === page.players[0].assetID);
    if (existing) mergeCandidate(existing, source);
    else {
      const incoming = structuredClone(source);
      if (page.players?.length === 1 && incoming.isMedia) {
        const player = page.players[0];
        incoming.assetID = player.assetID; incoming.id = player.assetID;
        if (player.title) { incoming.title = player.title; incoming.titleSource = player.titleSource; }
        if (player.thumbnailURL) { incoming.thumbnailURL = player.thumbnailURL; incoming.thumbnailSource = player.thumbnailSource; }
      }
      const logical = result.find(item => incoming.assetID && item.assetID === incoming.assetID);
      if (logical) mergeCandidate(logical, incoming); else result.push(incoming);
    }
    if (result.length === MAX_CANDIDATES) break;
  }
  return result.map(item => ({ ...item, protected: item.protected || (item.isMedia && page.protectedMedia > 0), usable: !(item.protected || (item.isMedia && page.protectedMedia > 0)) && (item.downloadable || item.reviewable) }));
}
export function usableMediaCount(candidates) { return candidates.filter(item => item.isMedia && item.usable).length; }

export function durableAcknowledgment(response, requestID) {
  return Boolean(response && response.protocolVersion === 1 && response.requestID === requestID && !response.error && typeof response.jobID === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(response.jobID));
}
export function reviewAcknowledgment(response, requestID) {
  return Boolean(response && response.protocolVersion === 1 && response.requestID === requestID && response.opened === true && !response.error && !response.jobID);
}
