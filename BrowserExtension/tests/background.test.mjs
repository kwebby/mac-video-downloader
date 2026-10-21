import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const state = {}, messages = [], responses = [], badges = [], registeredScripts = [];
const frames = new Map();
const folderID = "853db606-838d-4fb6-a88f-623735bbdd17";
const testPreview = { title: "Real resolved film", isDirectFile: false, formats: [{ id: "22", label: "720p · MP4", height: 720, hasVideo: true, hasAudio: true }, { id: "140", label: "M4A audio", hasVideo: false, hasAudio: true }], qualities: [{ id: "best", label: "Best available" }, { id: "720p", label: "720p", height: 720 }] };
const grantedOrigins = new Set();
let onMessage, onContextMenu;
let tab = { id: 7, url: "https://public-site.com/watch", title: "Example page", incognito: false };
let documentID = "document-one";
let domSnapshot = { pageURL: tab.url, title: tab.title, observations: [], players: [] };
let replaceSavedFrame = false;
const extensionURL = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/";
const event = () => ({ listeners: [], addListener(listener) { this.listeners.push(listener); }, emit(...args) { this.listeners.forEach(listener => listener(...args)); } });
const makeStore = () => ({
  async get(keys) { return Object.fromEntries((keys === null ? Object.keys(state) : Array.isArray(keys) ? keys : [keys]).filter(key => key in state).map(key => [key, structuredClone(state[key])])); },
  async set(values) {
    Object.assign(state, structuredClone(values));
    if (replaceSavedFrame) for (const key of Object.keys(values).filter(key => key.startsWith("playerFrame:"))) state[key].players = [];
  },
  async remove(keys) { for (const key of Array.isArray(keys) ? keys : [keys]) delete state[key]; }
});
globalThis.chrome = {
  runtime: {
    id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", getURL: path => extensionURL + path,
    onInstalled: event(), onStartup: event(),
    onMessage: { addListener(listener) { onMessage = listener; } },
    async sendMessage() {},
    connectNative() {
      const port = { onMessage: event(), onDisconnect: event(),
        disconnect() { this.onDisconnect.emit(); },
        postMessage(request) {
          messages.push(structuredClone(request));
          const mode = responses.shift() || "accept";
          queueMicrotask(() => {
            if (mode === "disconnect") this.disconnect();
            else {
              const value = mode === "reject" ? { error: "Rejected by desktop" } : mode === "unsupported" ? { error: "Could not resolve this video. ERROR: Unsupported URL: [redacted]" } : mode === "authRequired" ? { error: "Sign in required" } : request.command === "openReview" && mode !== "wrongReview" ? { opened: true } : request.command === "resolveMedia" ? { mediaPreview: testPreview, folders: [{ id: folderID, name: "Films", path: "/private/never-expose", icon: "film" }], defaultFolderName: "Default MVD folder" } : request.command === "hello" ? { serviceVersion: "0.4.0", reviewAvailable: true, mediaPanelAvailable: true } : { jobID: "d149a8db-153c-4c22-83e1-d8a4e0570f60" };
              this.onMessage.emit({ protocolVersion: 1, requestID: request.requestID, ...value });
            }
          });
        }
      };
      return port;
    }
  },
  tabs: { async query() { return [tab]; }, async get(id) { return { ...tab, id }; }, async sendMessage() { return { opened: true }; }, onUpdated: event(), onActivated: event(), onRemoved: event() },
  webNavigation: { async getFrame({ frameId }) { return frameId ? frames.get(frameId) : { url: tab.url, documentId: documentID, documentLifecycle: "active" }; }, onCommitted: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event() },
  webRequest: { onHeadersReceived: event() },
  permissions: { async contains({ origins }) { return origins.every(origin => grantedOrigins.has(origin)); }, async getAll() { return { origins: [...grantedOrigins] }; }, onAdded: event(), onRemoved: event() },
  scripting: { async executeScript() { return [{ result: structuredClone(domSnapshot), documentId: documentID }]; }, async unregisterContentScripts() {}, async registerContentScripts(values) { registeredScripts.push(...values); } },
  storage: { session: makeStore(), local: makeStore() },
  action: { async setBadgeText(value) { badges.push(value); }, async setBadgeBackgroundColor() {}, async setTitle() {} },
  contextMenus: { onClicked: { addListener(listener) { onContextMenu = listener; } }, removeAll(callback) { callback(); }, create() {} }
};
await import("../background.js");
const popupSender = { id: chrome.runtime.id, url: extensionURL + "popup.html" };
const invoke = message => new Promise(resolve => onMessage(message, popupSender, resolve));
const observe = raw => new Promise(resolve => onMessage({ type: "mediaObserved", snapshot: raw }, { id: chrome.runtime.id, url: raw.pageURL, tab, frameId: 0, documentId: documentID, documentLifecycle: "active" }, resolve));
const flush = () => new Promise(resolve => setTimeout(resolve, 20));
const snapshot = observations => ({ pageURL: tab.url, title: tab.title, observations, players: [], inaccessibleMedia: 0, protectedMedia: 0 });

test("transport retry reuses exact IDs and only durable acknowledgment clears pending state", async () => {
  responses.push("disconnect", "accept");
  const result = await invoke({ type: "enqueue", url: "https://cdn.public-site.com/video.mp4?signature=exact", sourcePageURL: tab.url });
  assert.equal(result.ok, true); assert.equal(result.accepted, true);
  assert.equal(messages.length, 2); assert.equal(messages[0].idempotencyKey, messages[1].idempotencyKey); assert.equal(messages[0].requestID, messages[1].requestID);
  assert.equal("tabID" in messages[0], false); assert.equal(state.pendingHandoff, undefined); assert.equal(state.lastResult.jobID, result.jobID);
});
test("unconfirmed handoff manual retry keeps its original key", async () => {
  responses.push("disconnect", "disconnect");
  const result = await invoke({ type: "enqueue", url: "https://cdn.public-site.com/other.mp4", sourcePageURL: tab.url });
  assert.equal(result.ok, false); const pending = structuredClone(state.pendingHandoff); assert.ok(pending.idempotencyKey);
  const retried = await invoke({ type: "retry" }); assert.equal(retried.ok, true); assert.equal(messages.at(-1).idempotencyKey, pending.idempotencyKey); assert.equal(messages.at(-1).requestID, pending.requestID); assert.equal(state.pendingHandoff, undefined);
});
test("definitive rejection clears outbox without reporting acceptance", async () => {
  responses.push("reject"); const result = await invoke({ type: "enqueue", url: "https://cdn.public-site.com/rejected.mp4", sourcePageURL: tab.url });
  assert.equal(result.ok, false); assert.equal(result.jobID, undefined); assert.equal(state.pendingHandoff, undefined);
});
test("review opens a composer and is never a durable download acknowledgment", async () => {
  const result = await invoke({ type: "openReview", url: "https://cdn.public-site.com/master.m3u8?token=exact", sourcePageURL: tab.url });
  assert.equal(result.ok, true); assert.equal(result.opened, true); assert.equal(result.accepted, undefined); assert.equal(result.jobID, undefined);
  assert.equal(messages.at(-1).command, "openReview"); assert.equal(messages.at(-1).idempotencyKey, undefined); assert.equal(state.lastResult.opened, true); assert.equal(state.pendingHandoff, undefined);
  responses.push("wrongReview"); const bad = await invoke({ type: "openReview", url: tab.url, sourcePageURL: tab.url }); assert.equal(bad.ok, false);
});
test("page/manifests require review rather than direct enqueue", async () => {
  const count = messages.length;
  for (const url of [tab.url, "https://cdn.public-site.com/master.m3u8", "https://cdn.public-site.com/manifest.mpd"]) {
    const result = await invoke({ type: "enqueue", url, sourcePageURL: tab.url }); assert.equal(result.ok, false); assert.match(result.error, /Review in MVD/);
  }
  assert.equal(messages.length, count);
});
test("main-frame DOM updates set per-tab numbered badges and group one player's variants", async () => {
  const raw = snapshot([{ url: "https://cdn.public-site.com/a.mp4?sig=1", title: "First video", kind: "media", assetID: "player-a" }, { url: "https://cdn.public-site.com/a.webm?sig=2", title: "First video", kind: "media", assetID: "player-a" }, { url: "https://cdn.public-site.com/b.mp4", title: "Second video", kind: "media", assetID: "player-b" }, { url: "https://public-site.com/image.jpg", kind: "file" }]);
  assert.equal((await observe(raw)).ok, true);
  const page = await invoke({ type: "snapshot" }); assert.equal(page.usableMediaCount, 2); assert.equal(page.candidates.length, 2); assert.equal(page.candidates[0].variants.length, 2);
  assert.deepEqual(badges.at(-1), { tabId: 7, text: "2" });
  const before = badges.length;
  await invoke({ type: "enqueue", url: "https://cdn.public-site.com/a.mp4?sig=1", sourcePageURL: tab.url }); assert.equal(badges.length, before, "job acceptance must not replace numbered badge with a tick");
});
test("passive network metadata requires exact site/CDN grants and excludes segments", async () => {
  const raw = snapshot([]); raw.players = [{ assetID: "blob-player", title: "Playing film", titleSource: "Video title" }]; raw.inaccessibleMedia = 1;
  await observe(raw);
  const details = { tabId: 7, frameId: 0, documentId: documentID, url: "https://cdn.public-site.com/opaque-manifest?sig=exact", type: "xmlhttprequest", statusCode: 200, initiator: "https://public-site.com", responseHeaders: [{ name: "Content-Type", value: "application/vnd.apple.mpegurl" }, { name: "Set-Cookie", value: "secret=never-store" }] };
  chrome.webRequest.onHeadersReceived.emit(details); await flush(); assert.equal((await invoke({ type: "snapshot" })).usableMediaCount, 0);
  grantedOrigins.add("https://public-site.com/*"); grantedOrigins.add("https://cdn.public-site.com/*"); chrome.permissions.onAdded.emit(); await flush();
  chrome.webRequest.onHeadersReceived.emit(details); await flush();
  const page = await invoke({ type: "snapshot" }); assert.equal(page.usableMediaCount, 1); assert.equal(page.candidates[0].url, details.url); assert.equal(page.candidates[0].title, "Playing film"); assert.equal(page.candidates[0].downloadable, false); assert.equal(page.candidates[0].reviewable, true);
  assert.equal(JSON.stringify(state).includes("never-store"), false);
  chrome.webRequest.onHeadersReceived.emit({ ...details, url: "https://cdn.public-site.com/segment-123.m4s", responseHeaders: [{ name: "content-type", value: "video/mp4" }] }); await flush(); assert.equal((await invoke({ type: "snapshot" })).usableMediaCount, 1);
});
test("DRM evidence suppresses usable counts and source actions", async () => {
  const raw = snapshot([{ url: "https://cdn.public-site.com/protected.mp4", kind: "media", assetID: "protected-player" }]); raw.protectedMedia = 1;
  await observe(raw); const page = await invoke({ type: "snapshot" }); assert.equal(page.usableMediaCount, 0); assert.equal(page.candidates[0].protected, true); assert.deepEqual(badges.at(-1), { tabId: 7, text: "0" });
  const count = messages.length; const action = await invoke({ type: "enqueue", url: raw.observations[0].url, sourcePageURL: tab.url }); assert.equal(action.ok, false); assert.equal(messages.length, count);
});
test("navigation clears old sources and rejects stale document network events", async () => {
  const oldDocument = documentID;
  tab = { ...tab, url: "https://public-site.com/next", title: "Next page" }; documentID = "document-two";
  chrome.webNavigation.onCommitted.emit({ tabId: 7, frameId: 0, url: tab.url, documentId: documentID }); await flush();
  domSnapshot = snapshot([]); await observe(domSnapshot);
  chrome.webRequest.onHeadersReceived.emit({ tabId: 7, frameId: 0, documentId: oldDocument, url: "https://cdn.public-site.com/late.mp4", type: "media", statusCode: 200, initiator: "https://public-site.com", responseHeaders: [{ name: "Content-Type", value: "video/mp4" }] }); await flush();
  assert.equal((await invoke({ type: "snapshot" })).usableMediaCount, 0);
  chrome.webNavigation.onHistoryStateUpdated.emit({ tabId: 7, frameId: 0, url: tab.url, documentId: documentID }); await flush(); assert.equal(state["mediaTab:7"], undefined);
});
test("permitted sites register packaged observer scripts; missing/blocked sources cannot send commands", async () => {
  const result = await invoke({ type: "permissionsChanged" }); assert.equal(result.ok, true); assert.equal(registeredScripts.at(-1).matches.includes("https://public-site.com/*"), true);
  const count = messages.length;
  assert.equal((await invoke({ type: "openReview", url: "https://youtu.be/aqz-KE-bpKQ", sourcePageURL: tab.url })).ok, true);
  const updatedCount = messages.length;
  const changed = await invoke({ type: "enqueue", url: "https://cdn.public-site.com/a.mp4", sourcePageURL: "https://different-site.com/" }); assert.equal(changed.ok, false);
  assert.equal(onMessage({ type: "retry" }, { ...popupSender, tab: { id: 7 }, frameId: 0, url: tab.url }, () => {}), false);
  assert.equal(messages.length, updatedCount);
  tab = { ...tab, url: "http://127.0.0.1/watch" }; onContextMenu({ menuItemId: "harbor-link", linkUrl: "https://cdn.public-site.com/a.mp4" }, tab); await flush(); assert.equal(messages.length, updatedCount); assert.equal(state.lastResult.failed, true);
});
test("desktop handshake reports explicit review capability", async () => {
  const result = await invoke({ type: "connection" }); assert.equal(result.ok, true); assert.equal(result.connected, true); assert.equal(result.reviewAvailable, true); assert.equal(result.serviceVersion, "0.4.0");
});
test("browser startup quietly verifies the native companion without queueing work", async () => {
  const before = messages.length;
  const priorOutbox = structuredClone(state.pendingHandoff);
  chrome.runtime.onStartup.emit();
  await flush();
  const requests = messages.slice(before);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].command, "hello");
  assert.equal(requests[0].url, undefined);
  assert.equal(requests[0].userGesture, undefined);
  assert.deepEqual(state.pendingHandoff, priorOutbox);
});

const invokeContent = message => new Promise(resolve => onMessage({ ...message, pageURL: tab.url }, { id: chrome.runtime.id, url: tab.url, tab, frameId: 0, documentId: documentID, documentLifecycle: "active" }, resolve));
test("private YouTube panel resolves actual formats and opaque folders, then enqueues its exact options once", async () => {
  tab = { ...tab, url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", title: "YouTube film" }; documentID = "youtube-panel-document";
  const raw = snapshot([{ url: tab.url, kind: "media", assetID: "yt-player", title: "Film" }]); raw.players = [{ assetID: "yt-player", title: "Film", targetURL: tab.url, playing: true }];
  assert.equal((await observe(raw)).ok, true);
  const result = await invokeContent({ type: "panelResolve", playerID: "yt-player" });
  assert.equal(result.ok, true); assert.equal(result.mediaPreview.formats[1].id, "140"); assert.equal(result.folders[0].id, folderID); assert.equal(result.folders[0].path, undefined); assert.equal(JSON.stringify(result).includes("never-expose"), false);
  assert.equal(messages.at(-1).command, "resolveMedia"); assert.equal(messages.at(-1).url, tab.url); assert.equal(messages.at(-1).userGesture, true);
  const options = { mode: "audioOnly", formatID: "140", container: "auto", audioFormat: "mp3", audioBitrateKbps: 192, accelerated: false };
  const payload = { type: "panelEnqueue", playerID: "yt-player", sessionToken: result.sessionToken, options, quality: { id: "720p" }, folderID };
  const accepted = await invokeContent(payload); assert.equal(accepted.ok, true); assert.equal(accepted.accepted, true); assert.ok(accepted.jobID);
  const native = messages.at(-1); assert.equal(native.command, "enqueueMedia"); assert.equal(native.options.audioBitrateKbps, 192); assert.equal(native.options.formatID, "140"); assert.equal(native.folderID, folderID); assert.equal(native.quality, undefined); assert.equal(native.userGesture, true); assert.equal(native.destinationDirectory, undefined);
  const count = messages.length; const duplicate = await invokeContent(payload); assert.equal(duplicate.jobID, accepted.jobID); assert.equal(messages.length, count);
  const forged = await invokeContent({ type: "panelResolve", playerID: "unrelated-player", url: "https://unrelated-site.com/video" }); assert.equal(forged.ok, false); assert.equal(messages.length, count);
});
test("disabled website persists and prevents player resolution without removing optional grants", async () => {
  const before = messages.length;
  assert.equal((await invokeContent({ type: "disableSite", disabled: true })).ok, true);
  assert.equal((await invokeContent({ type: "overlayState" })).disabled, true); assert.equal(state.disabledSites.includes("youtube.com"), true);
  assert.equal((await invokeContent({ type: "panelResolve", playerID: "yt-player" })).ok, false); assert.equal(messages.length, before);
  const enabled = await invoke({ type: "toggleSite", sourcePageURL: tab.url, disabled: false }); assert.equal(enabled.ok, true); assert.equal(state.disabledSites.includes("youtube.com"), false);
});
test("iframe actions are bound to their own live frame and document", async () => {
  const frameURL = "https://player.vimeo.com/video/12345678"; frames.set(3, { url: frameURL, documentId: "vimeo-frame", documentLifecycle: "active" });
  const sender = { id: chrome.runtime.id, url: frameURL, tab, frameId: 3, documentId: "vimeo-frame", documentLifecycle: "active" };
  const frameCall = message => new Promise(resolve => onMessage({ ...message, pageURL: frameURL }, sender, resolve));
  const raw = { pageURL: frameURL, title: "Embedded film", observations: [], players: [{ assetID: "iframe-player", title: "Embedded film", targetURL: frameURL }] };
  assert.equal((await frameCall({ type: "mediaObserved", snapshot: raw })).ok, true);
  const preview = await frameCall({ type: "panelResolve", playerID: "iframe-player" }); assert.equal(preview.ok, true); assert.equal(messages.at(-1).sourcePageURL, frameURL);
  frames.set(3, { url: frameURL, documentId: "new-frame-document" });
  const count = messages.length; assert.equal((await frameCall({ type: "panelResolve", playerID: "iframe-player" })).ok, false); assert.equal(messages.length, count);
});
test("a clicked reel's fresh snapshot survives large posters and concurrent storage replacement", async () => {
  tab = { ...tab, url: "https://www.instagram.com/reels/CurrentVideo/", title: "Reels" }; documentID = "instagram-panel-document";
  const raw = snapshot([]);
  raw.players = Array.from({ length: 80 }, (_, index) => ({ assetID: `reel-${index}`, title: `Reel ${index}`, thumbnailURL: `https://cdn.public-site.com/poster.jpg?sig=${"s".repeat(1500)}`, targetURL: `https://www.instagram.com/reel/Reel${index}/` }));
  assert.equal((await observe(raw)).ok, true);
  for (const key of ["playerFrame:7:0", "mediaTab:7"]) { assert.equal(state[key].players.length, 80); assert.ok(JSON.stringify(state[key]).length < 90 * 1024); }
  const before = messages.length;
  replaceSavedFrame = true;
  try {
    const resolved = await invokeContent({ type: "panelResolve", playerID: "reel-79", snapshot: raw });
    assert.equal(resolved.ok, true); assert.equal(messages.length, before + 1);
    assert.equal(messages.at(-1).url, raw.players[79].targetURL);
    assert.equal(state["playerFrame:7:0"].players.length, 0, "a periodic snapshot can replace cached player details");
    const accepted = await invokeContent({ type: "panelEnqueue", playerID: "reel-79", snapshot: raw, sessionToken: resolved.sessionToken, options: { mode: "audioOnly", audioFormat: "mp3", audioBitrateKbps: 128 } });
    assert.equal(accepted.ok, true); assert.equal(accepted.accepted, true);
    assert.equal(messages.at(-1).command, "enqueueMedia"); assert.equal(messages.at(-1).url, raw.players[79].targetURL);
  } finally { replaceSavedFrame = false; }
});
test("fresh player commands reject mismatched snapshot pages, oversize payloads and changed targets", async () => {
  const raw = snapshot([]); raw.players = [{ assetID: "current-reel", targetURL: "https://www.instagram.com/reel/CurrentVideo/" }];
  const before = messages.length;
  for (const stale of [{ ...raw, pageURL: "https://www.instagram.com/reels/OldVideo/" }, { ...raw, oversized: "s".repeat(257 * 1024) }, null]) {
    const result = await invokeContent({ type: "panelResolve", playerID: "current-reel", snapshot: stale });
    assert.equal(result.ok, false); assert.equal(messages.length, before);
  }
  const resolved = await invokeContent({ type: "panelResolve", playerID: "current-reel", snapshot: raw }); assert.equal(resolved.ok, true);
  const count = messages.length;
  const changed = structuredClone(raw); changed.players[0].targetURL = "https://www.instagram.com/reel/DifferentVideo/";
  const result = await invokeContent({ type: "panelEnqueue", playerID: "current-reel", snapshot: changed, sessionToken: resolved.sessionToken, options: { mode: "audioOnly", audioFormat: "mp3" } });
  assert.equal(result.ok, false); assert.match(result.error, /selected video changed/); assert.equal(messages.length, count);
});
test("same-document SPA navigation accepts the original sender URL only for the live frame route", async () => {
  const originalURL = tab.url;
  tab = { ...tab, url: "https://www.instagram.com/reels/NextVideo/" };
  const sender = { id: chrome.runtime.id, url: originalURL, tab, frameId: 0, documentId: documentID, documentLifecycle: "active" };
  const call = message => new Promise(resolve => onMessage({ ...message, pageURL: tab.url }, sender, resolve));
  const raw = snapshot([]); raw.players = [{ assetID: "next-reel", targetURL: "https://www.instagram.com/reel/NextVideo/" }];
  const resolved = await call({ type: "panelResolve", playerID: "next-reel", snapshot: raw });
  assert.equal(resolved.ok, true); assert.equal(messages.at(-1).url, raw.players[0].targetURL);
  const count = messages.length;
  const staleRoute = await new Promise(resolve => onMessage({ type: "panelResolve", playerID: "next-reel", pageURL: originalURL, snapshot: { ...raw, pageURL: originalURL } }, sender, resolve));
  assert.equal(staleRoute.ok, false); assert.equal(messages.length, count);
  const originalDocument = documentID; documentID = "new-instagram-document";
  const staleDocument = await call({ type: "panelResolve", playerID: "next-reel", snapshot: raw });
  assert.equal(staleDocument.ok, false); assert.equal(messages.length, count);
  documentID = originalDocument;
  const foreignSender = { ...sender, url: "https://unrelated-site.com/" };
  const foreign = await new Promise(resolve => onMessage({ type: "panelResolve", playerID: "next-reel", pageURL: tab.url, snapshot: raw }, foreignSender, resolve));
  assert.equal(foreign.ok, false); assert.equal(messages.length, count);
});
test("unsupported post extraction falls back only to the selected player's exact signed media source", async () => {
  tab = { ...tab, url: "https://www.linkedin.com/feed/update/urn:li:activity:1234567890123456789/", title: "LinkedIn post" }; documentID = "linkedin-panel-document";
  const source = "https://cdn.public-site.com/master.m3u8?signature=a%2Fb&token=keep-exact";
  const raw = snapshot([
    { url: "https://cdn.public-site.com/other.mp4", kind: "media", assetID: "other-player" },
    { url: "https://cdn.public-site.com/unattributed.mp4", kind: "resource" },
    { url: source, kind: "media", assetID: "selected-player" }
  ]);
  raw.players = [{ assetID: "other-player", targetURL: "https://public-site.com/other" }, { assetID: "selected-player", targetURL: tab.url }];
  responses.push("unsupported", "accept"); const before = messages.length;
  const resolved = await invokeContent({ type: "panelResolve", playerID: "selected-player", snapshot: raw, url: "https://unrelated-site.com/forged.mp4" });
  assert.equal(resolved.ok, true); assert.equal(messages.length, before + 2);
  assert.equal(messages.at(-2).url, tab.url); assert.equal(messages.at(-1).url, source);
  const missingSource = structuredClone(raw); missingSource.observations = missingSource.observations.filter(item => item.url !== source);
  const selection = { type: "panelEnqueue", playerID: "selected-player", sessionToken: resolved.sessionToken, options: { mode: "audioOnly", audioFormat: "mp3", audioBitrateKbps: 128 } };
  const changed = await invokeContent({ ...selection, snapshot: missingSource });
  assert.equal(changed.ok, false); assert.match(changed.error, /selected video changed/); assert.equal(messages.length, before + 2);
  const accepted = await invokeContent({ ...selection, snapshot: raw });
  assert.equal(accepted.ok, true); assert.equal(accepted.accepted, true); assert.equal(messages.at(-1).command, "enqueueMedia"); assert.equal(messages.at(-1).url, source);
});
test("unsupported pages without attributed sources show recovery guidance without guessing another player's video", async () => {
  const raw = snapshot([{ url: "https://cdn.public-site.com/other.mp4", kind: "media", assetID: "other-player" }, { url: "https://cdn.public-site.com/unattributed.mp4", kind: "resource" }]);
  raw.players = [{ assetID: "selected-player", targetURL: tab.url }, { assetID: "other-player", targetURL: "https://public-site.com/other" }];
  responses.push("unsupported"); const before = messages.length;
  const result = await invokeContent({ type: "panelResolve", playerID: "selected-player", snapshot: raw, url: "https://unrelated-site.com/forged.mp4" });
  assert.equal(result.ok, false); assert.match(result.error, /Start the video/); assert.equal(messages.length, before + 1); assert.equal(messages.at(-1).url, tab.url);
});
test("unsupported post extraction can resolve its MIME-identified extensionless player source", async () => {
  const source = "https://cdn.public-site.com/playback?id=7&signature=keep%2Fexact";
  const raw = snapshot([
    { url: source, kind: "media", assetID: "selected-player" },
    { url: source, kind: "media", assetID: "selected-player", mime: "video/mp4" },
    { url: "https://cdn.public-site.com/other", kind: "media", assetID: "other-player", mime: "video/mp4" }
  ]);
  raw.players = [{ assetID: "selected-player", targetURL: tab.url }, { assetID: "other-player", targetURL: "https://public-site.com/other" }];
  responses.push("unsupported", "accept"); const before = messages.length;
  const resolved = await invokeContent({ type: "panelResolve", playerID: "selected-player", snapshot: raw });
  assert.equal(resolved.ok, true); assert.equal(messages.length, before + 2);
  assert.equal(messages.at(-2).url, tab.url); assert.equal(messages.at(-1).url, source);
  const accepted = await invokeContent({ type: "panelEnqueue", playerID: "selected-player", snapshot: raw, sessionToken: resolved.sessionToken, options: { mode: "audioOnly", audioFormat: "mp3" } });
  assert.equal(accepted.ok, true); assert.equal(messages.at(-1).url, source);
});
test("authentication failures never trigger observed-source fallback", async () => {
  const raw = snapshot([{ url: "https://cdn.public-site.com/source.mp4?signature=exact", kind: "media", assetID: "selected-player" }]);
  raw.players = [{ assetID: "selected-player", targetURL: tab.url }];
  responses.push("authRequired"); const before = messages.length;
  const result = await invokeContent({ type: "panelResolve", playerID: "selected-player", snapshot: raw });
  assert.equal(result.ok, false); assert.match(result.error, /Sign in required/); assert.equal(messages.length, before + 1);
});
test("a selected feed player's observed media is primary when no provider permalink exists", async () => {
  tab = { ...tab, url: "https://www.linkedin.com/feed/", title: "LinkedIn feed" };
  const source = "https://cdn.public-site.com/player.mp4?signature=exact%2Fvalue";
  const raw = snapshot([{ url: source, kind: "media", assetID: "feed-player" }]); raw.players = [{ assetID: "feed-player", targetURL: null }];
  const before = messages.length;
  const resolved = await invokeContent({ type: "panelResolve", playerID: "feed-player", snapshot: raw });
  assert.equal(resolved.ok, true); assert.equal(messages.length, before + 1); assert.equal(messages.at(-1).url, source);
  assert.equal(state.mediaPanelSessions.at(-1).playerTarget, null);
  const accepted = await invokeContent({ type: "panelEnqueue", playerID: "feed-player", snapshot: raw, sessionToken: resolved.sessionToken, options: { mode: "videoWithAudio" } });
  assert.equal(accepted.ok, true); assert.equal(accepted.accepted, true); assert.equal(messages.at(-1).url, source);
  const empty = snapshot([]); empty.players = raw.players;
  const count = messages.length;
  const unavailable = await invokeContent({ type: "panelResolve", playerID: "feed-player", snapshot: empty });
  assert.equal(unavailable.ok, false); assert.match(unavailable.error, /Start playback/); assert.equal(messages.length, count);
});
