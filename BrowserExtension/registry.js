import { cleanText, collectCandidates, MAX_CANDIDATES, mergePageCandidates, safeThumbnail, usableMediaCount, validatePublicURL } from "./core.js";

export const MAX_TAB_REGISTRIES = 32;
export const MAX_NETWORK_AGE_MS = 10 * 60 * 1000;
export function freshRegistry(tabID, pageURL, title = "", documentID = null) {
  return { tabID, pageURL: validatePublicURL(pageURL), title: cleanText(title) || new URL(pageURL).hostname, documentID, epoch: crypto.randomUUID(), updatedAt: Date.now(), dom: [], network: [], players: [], inaccessibleMedia: 0, protectedMedia: 0, inspected: false };
}
export function applySnapshot(previous, tabID, raw, documentID = null) {
  const pageURL = validatePublicURL(raw?.pageURL);
  const changed = !previous || previous.pageURL !== pageURL || (documentID && previous.documentID && previous.documentID !== documentID);
  const registry = changed ? freshRegistry(tabID, pageURL, raw.title, documentID) : structuredClone(previous);
  registry.documentID = documentID || registry.documentID;
  registry.title = cleanText(raw.title) || registry.title;
  registry.pageImage = safeThumbnail(raw.pageImage, pageURL);
  registry.players = (Array.isArray(raw.players) ? raw.players.slice(0, 80) : []).map(player => ({ assetID: cleanText(player.assetID, 80), title: cleanText(player.title) || registry.title, titleSource: cleanText(player.titleSource, 40) || "Page title fallback", thumbnailURL: safeThumbnail(player.thumbnailURL || registry.pageImage, pageURL), thumbnailSource: cleanText(player.thumbnailSource, 40) || "Page image fallback", protected: player.protected === true, targetURL: (() => { try { return player.targetURL ? validatePublicURL(player.targetURL) : null; } catch { return null; } })(), ad: player.ad === true, playing: player.playing === true }));
  registry.frameOrigins = (Array.isArray(raw.frameOrigins) ? raw.frameOrigins : []).slice(0, 16).filter(origin => { try { validatePublicURL(origin); return true; } catch { return false; } });
  registry.inaccessibleMedia = Math.max(0, Math.min(80, Number(raw.inaccessibleMedia) || 0));
  registry.protectedMedia = Math.max(0, Math.min(80, Number(raw.protectedMedia) || 0));
  registry.dom = collectCandidates(raw.observations, pageURL, { pageTitle: registry.title, pageImage: registry.pageImage });
  registry.inspected = true;
  registry.updatedAt = Date.now();
  registry.network = registry.network.filter(item => registry.updatedAt - item.observedAt < MAX_NETWORK_AGE_MS).slice(-MAX_CANDIDATES);
  return registry;
}
export function applyNetworkObservation(previous, tabID, pageURL, observation, title = "") {
  const registry = previous?.pageURL === pageURL ? structuredClone(previous) : freshRegistry(tabID, pageURL, title);
  const candidate = collectCandidates([{ ...observation, kind: "network" }], pageURL, { pageTitle: registry.title, pageImage: registry.pageImage })[0];
  if (!candidate?.isMedia) return registry;
  const existing = registry.network.find(item => item.url === candidate.url);
  if (existing) existing.observedAt = Date.now();
  else registry.network.push({ ...candidate, observedAt: Date.now() });
  registry.network = registry.network.filter(item => Date.now() - item.observedAt < MAX_NETWORK_AGE_MS).slice(-MAX_CANDIDATES);
  registry.updatedAt = Date.now();
  return registry;
}
// Poster URLs often contain long signatures. They must not evict the compact
// player identity and source that a live download button is bound to.
export function compactRegistry(registry, maxCharacters, preferredPlayerID = null) {
  const oversized = () => JSON.stringify(registry).length > maxCharacters;
  if (!oversized()) return registry;
  registry.pageImage = null;
  for (const player of registry.players) { player.thumbnailURL = null; player.thumbnailSource = "No thumbnail exposed"; }
  for (const candidate of [...registry.dom, ...registry.network]) {
    candidate.thumbnailURL = null; candidate.thumbnailSource = "No thumbnail exposed";
    for (const variant of candidate.variants || []) { variant.thumbnailURL = null; variant.thumbnailSource = "No thumbnail exposed"; }
  }
  while (oversized() && (registry.network.length || registry.dom.length)) {
    if (registry.network.length) registry.network.shift(); else registry.dom.pop();
  }
  // Keep every bounded player record whenever possible. If unusually long
  // source URLs alone exceed the budget, retain the explicitly clicked player.
  if (preferredPlayerID) registry.players.sort((a, b) => Number(b.assetID === preferredPlayerID) - Number(a.assetID === preferredPlayerID));
  while (oversized() && registry.players.length) registry.players.pop();
  return registry;
}
export function registrySnapshot(registry) {
  const network = registry.network.filter(item => Date.now() - item.observedAt < MAX_NETWORK_AGE_MS);
  const candidates = mergePageCandidates(registry.dom, network, registry);
  return { ...registry, dom: undefined, network: undefined, candidates, usableMediaCount: usableMediaCount(candidates) };
}
