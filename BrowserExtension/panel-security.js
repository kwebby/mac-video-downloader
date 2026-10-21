import { cleanText, isNetworkMedia, validatePublicURL } from "./core.js";
export const PANEL_TTL_MS = 10 * 60 * 1000;
export function safeMediaPreview(raw) {
  if (!raw || typeof raw.title !== "string") throw new Error("MVD did not return usable media information.");
  const qualities = (Array.isArray(raw.qualities) ? raw.qualities : []).filter(item => typeof item?.id === "string" && item.id.length <= 80).slice(0, 40).map(item => ({ id: item.id, label: cleanText(item.label, 120) || item.id, ...(Number.isInteger(item.height) ? { height: item.height } : {}) }));
  const formats = (Array.isArray(raw.formats) ? raw.formats : []).filter(item => typeof item?.id === "string" && item.id.length <= 160 && !/[\u0000-\u001f]/.test(item.id)).slice(0, 400).map(item => ({ id: item.id, label: cleanText(item.label, 200) || item.id, hasVideo: item.hasVideo === true, hasAudio: item.hasAudio === true, container: cleanText(item.container, 20), height: Number.isFinite(item.height) ? item.height : undefined, fps: Number.isFinite(item.fps) ? item.fps : undefined }));
  return { title: cleanText(raw.title, 200), isDirectFile: raw.isDirectFile === true, qualities: qualities.length ? qualities : [{ id: "best", label: "Best available" }], formats };
}
export function safeFolders(raw) { return (Array.isArray(raw) ? raw : []).filter(folder => /^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(folder?.id)).slice(0, 100).map(folder => ({ id: folder.id, name: cleanText(folder.name, 100) || "MVD folder", icon: cleanText(folder.icon, 40), colorHex: /^#[0-9a-f]{6}$/i.test(folder.colorHex || "") ? folder.colorHex : undefined })); }
export function validateSelection(session, input) {
  const mode = input.options?.mode;
  if (!["videoWithAudio", "videoOnly", "audioOnly"].includes(mode)) throw new Error("Choose a supported video or audio mode.");
  const options = { mode, container: input.options.container || "auto", audioFormat: input.options.audioFormat || "original", accelerated: false };
  if (!["auto", "mp4", "mkv", "webm"].includes(options.container) || !["original", "m4a", "mp3", "opus", "wav", "flac"].includes(options.audioFormat)) throw new Error("Choose a supported output format.");
  if (input.options.formatID) {
    const format = session.mediaPreview.formats.find(item => item.id === input.options.formatID);
    if (!format || (mode === "audioOnly" ? !format.hasAudio : !format.hasVideo)) throw new Error("That source format is no longer available. Resolve the video again.");
    options.formatID = format.id;
  }
  if (input.options.audioBitrateKbps !== undefined) {
    if (mode !== "audioOnly" || !["m4a", "mp3", "opus"].includes(options.audioFormat)) throw new Error("A fixed bitrate is available only for M4A, MP3 or Opus audio.");
    if (![64, 96, 128, 160, 192, 256, 320].includes(input.options.audioBitrateKbps)) throw new Error("Choose a supported audio bitrate.");
    options.audioBitrateKbps = input.options.audioBitrateKbps;
  }
  const quality = session.mediaPreview.qualities.find(item => item.id === (input.quality?.id || "best"));
  if (mode !== "audioOnly" && !options.formatID && !quality) throw new Error("Choose a quality returned by MVD.");
  if (input.folderID && !session.folders.some(folder => folder.id === input.folderID)) throw new Error("The folder is no longer available. Resolve the video again.");
  if (session.mediaPreview.isDirectFile && (mode !== "videoWithAudio" || options.formatID || options.container !== "auto" || options.audioFormat !== "original")) throw new Error("Direct files are saved in their original format.");
  return { options, ...(mode !== "audioOnly" && !options.formatID ? { quality } : {}), ...(input.folderID ? { folderID: input.folderID } : {}) };
}
function selectedPlayer(registry, playerID) {
  const player = registry?.players.find(item => item.assetID === playerID);
  if (!player) throw new Error("This player changed or is no longer on the page. Open its download button again.");
  if (player.protected) throw new Error("This player uses protected playback and cannot be downloaded.");
  if (player.ad) throw new Error("Advertisement players are unavailable for download.");
  return player;
}
export function playerTarget(registry, playerID) {
  const player = selectedPlayer(registry, playerID);
  if (!player.targetURL) throw new Error("This player does not expose a separate source URL. Open its original video page and try again.");
  return validatePublicURL(player.targetURL);
}
export function playerMediaBinding(registry, playerID) {
  const player = selectedPlayer(registry, playerID);
  const primaryTarget = player.targetURL ? validatePublicURL(player.targetURL) : null;
  // Use only actual source observations explicitly attributed to this player.
  // Unattributed performance entries and another feed card's sources never
  // become a fallback, even when there is only one currently visible video.
  const sourceTargets = [];
  for (const candidate of registry.dom || []) {
    if (candidate.assetID !== playerID || candidate.protected || !candidate.isMedia) continue;
    for (const source of [{ url: candidate.url }, ...(candidate.variants || [])]) {
      try {
        const url = validatePublicURL(source.url);
        if (url !== registry.pageURL && isNetworkMedia(url, source.mime || "", "other") && !sourceTargets.includes(url)) sourceTargets.push(url);
      } catch { /* Invalid observed resources never become native requests. */ }
    }
  }
  if (!primaryTarget && !sourceTargets.length) throw new Error("This player has not exposed a downloadable source yet. Start playback, wait a moment, then open its download button again.");
  return { primaryTarget, sourceTargets: sourceTargets.slice(0, 8) };
}
export function unsupportedMediaPage(error) {
  const message = typeof error === "string" ? error : "";
  if (/\b(?:DRM|protected|authentication|cookies?|403|429)\b|\b(?:sign|log)[ -]?in\b/i.test(message)) return false;
  return /\bunsupported\s+(?:url|site|webpage)\b|\bno suitable extractor\b|\bno (?:video|media)(?: formats?)? found\b|\bthis (?:site|url) is not supported\b/i.test(message);
}
