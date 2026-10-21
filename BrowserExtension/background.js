import { collectCandidates, durableAcknowledgment, isDirectDownloadURL, isNetworkMedia, originPattern, reviewAcknowledgment, validatePublicURL } from "./core.js";
import { safeMediaPreview, safeFolders, validateSelection, playerMediaBinding, unsupportedMediaPage, PANEL_TTL_MS } from "./panel-security.js";
import { applyNetworkObservation, applySnapshot, compactRegistry, freshRegistry, MAX_TAB_REGISTRIES, registrySnapshot } from "./registry.js";

const HOST = "io.harbor.downloads";
const OUTBOX_KEY = "pendingHandoff";
const REGISTRY_PREFIX = "mediaTab:";
const queues = new Map();
const scanTimers = new Map();
const pendingReplies = new Map();
let registryIndexQueue = Promise.resolve();
let frameIndexQueue = Promise.resolve();
let contentScriptQueue = Promise.resolve();
let nativePort = null;
let nativeHeartbeat = null;
let enqueueInFlight = false;

function serialized(tabID, operation) {
  const next = (queues.get(tabID) || Promise.resolve()).catch(() => {}).then(operation);
  queues.set(tabID, next);
  next.finally(() => { if (queues.get(tabID) === next) queues.delete(tabID); }).catch(() => {});
  return next;
}
async function loadRegistry(tabID) { return (await chrome.storage.session.get(REGISTRY_PREFIX + tabID))[REGISTRY_PREFIX + tabID] || null; }
async function badge(tabID, registry = null) {
  const snapshot = registry ? registrySnapshot(registry) : null;
  const count = snapshot?.usableMediaCount || 0;
  await chrome.action.setBadgeText({ tabId: tabID, text: count ? String(count) : registry?.inspected ? "0" : "" });
  await chrome.action.setBadgeBackgroundColor({ tabId: tabID, color: count ? "#236454" : "#68766f" });
  await chrome.action.setTitle({ tabId: tabID, title: registry ? `MVD · ${count} available media source${count === 1 ? "" : "s"} · ${registry.title}` : "MVD · open the companion to inspect this page" });
}
async function saveRegistry(registry) {
  // Bound both per-tab payloads and tab count below Chrome session storage's quota.
  compactRegistry(registry, 100 * 1024);
  await chrome.storage.session.set({ [REGISTRY_PREFIX + registry.tabID]: registry });
  registryIndexQueue = registryIndexQueue.catch(() => {}).then(async () => {
    const prior = (await chrome.storage.session.get("mediaTabIndex")).mediaTabIndex || [];
    const index = [...prior.filter(id => id !== registry.tabID), registry.tabID];
    while (index.length > MAX_TAB_REGISTRIES) {
      const removed = index.shift();
      await chrome.storage.session.remove(REGISTRY_PREFIX + removed);
      await badge(removed).catch(() => {});
    }
    await chrome.storage.session.set({ mediaTabIndex: index });
  });
  await registryIndexQueue;
  await badge(registry.tabID, registry);
  chrome.runtime.sendMessage({ type: "registryChanged", tabID: registry.tabID }).catch(() => {});
}
async function clearTab(tabID) {
  await serialized(tabID, async () => {
    await chrome.storage.session.remove(REGISTRY_PREFIX + tabID);
    await badge(tabID).catch(() => {});
  });
}

function disconnectNative() {
  const port = nativePort; nativePort = null;
  clearInterval(nativeHeartbeat); nativeHeartbeat = null;
  if (port) { try { port.disconnect(); } catch { /* Already closed. */ } }
}
function connectedPort() {
  if (nativePort) return nativePort;
  const port = chrome.runtime.connectNative(HOST);
  nativePort = port;
  port.onMessage.addListener(response => {
    if (!response || response.protocolVersion !== 1 || typeof response.requestID !== "string") return;
    const waiting = pendingReplies.get(response.requestID);
    if (!waiting || waiting.port !== port) return;
    pendingReplies.delete(response.requestID); clearTimeout(waiting.timer); waiting.resolve(response);
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (nativePort === port) {
      nativePort = null;
      clearInterval(nativeHeartbeat); nativeHeartbeat = null;
    }
    for (const [id, waiting] of pendingReplies) if (waiting.port === port) {
      clearTimeout(waiting.timer); pendingReplies.delete(id);
      waiting.reject(new Error("The desktop connection closed. Open MVD and check companion installation."));
    }
  });
  return port;
}
function nativeRequest(request, timeoutMS = 15000) {
  return new Promise((resolve, reject) => {
    let port;
    try { port = connectedPort(); } catch { reject(new Error("MVD is unavailable. Build the app and register its Chrome native host.")); return; }
    const timer = setTimeout(() => {
      pendingReplies.delete(request.requestID);
      reject(new Error("MVD did not confirm this request. Retry uses the same request key."));
      disconnectNative();
    }, timeoutMS);
    pendingReplies.set(request.requestID, { resolve, reject, timer, port });
    try { port.postMessage(request); }
    catch { clearTimeout(timer); pendingReplies.delete(request.requestID); reject(new Error("MVD is unavailable. Check the desktop app and native host setup.")); disconnectNative(); }
  });
}
async function setResult(result) {
  // The badge always remains a per-tab media count, never a connection/job status icon.
  await chrome.storage.session.set({ lastResult: { ...result, at: Date.now() } });
}
async function handoff(request, tabID = null) {
  if (enqueueInFlight) throw new Error("A handoff is in progress. Wait for its result before trying again.");
  enqueueInFlight = true;
  try {
    validatePublicURL(request.url); validatePublicURL(request.sourcePageURL);
    if (request.command !== "enqueueMedia" && !isDirectDownloadURL(request.url)) throw new Error("Choose Review in MVD for this page or streaming source.");
    const existing = (await chrome.storage.session.get(OUTBOX_KEY))[OUTBOX_KEY];
    if (existing && existing.idempotencyKey !== request.idempotencyKey) {
      const intent = value => JSON.stringify({ command: value.command, url: value.url, sourcePageURL: value.sourcePageURL, options: value.options, quality: value.quality, folderID: value.folderID });
      if (intent(existing) === intent(request)) request = existing;
      else throw new Error("A previous download still needs confirmation. Use Retry pending download first.");
    }
    await chrome.storage.session.set({ [OUTBOX_KEY]: { ...request, tabID: tabID ?? request.tabID } });
    const { tabID: ignoredTab, ...wire } = request;
    let response;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try { response = await nativeRequest(wire, request.command === "enqueueMedia" ? 100000 : 15000); break; }
      catch (error) { if (attempt === 1) throw error; await new Promise(resolve => setTimeout(resolve, 250)); }
    }
    if (!durableAcknowledgment(response, request.requestID)) {
      if (response?.error) await chrome.storage.session.remove(OUTBOX_KEY);
      throw new Error(response?.error || "MVD did not return a durable job confirmation. Retry this download.");
    }
    await chrome.storage.session.remove(OUTBOX_KEY);
    await setResult({ message: "Download accepted by MVD. View progress in the desktop app.", jobID: response.jobID, failed: false, tabID: tabID ?? request.tabID });
    return { jobID: response.jobID, accepted: true };
  } finally { enqueueInFlight = false; }
}
async function openReview(url, sourcePageURL, tabID) {
  const request = { protocolVersion: 1, requestID: crypto.randomUUID(), command: "openReview", url: validatePublicURL(url), sourcePageURL: validatePublicURL(sourcePageURL), userGesture: true };
  const response = await nativeRequest(request);
  if (!reviewAcknowledgment(response, request.requestID)) throw new Error(response?.error || "MVD did not confirm opening its review window. No download was queued.");
  await setResult({ message: "Review opened in MVD. Click Review Link there, choose quality, then Download.", opened: true, failed: false, tabID });
  return { opened: true };
}
async function checkConnection() {
  try {
    const requestID = crypto.randomUUID();
    const response = await nativeRequest({ protocolVersion: 1, requestID, command: "hello" });
    if (response.error || response.requestID !== requestID) throw new Error(response.error || "The desktop app returned an incompatible response.");
    if (response.serviceVersion !== "0.4.0") throw new Error("Update and rebuild MVD and its companion together (service 0.4.0 required).");
    if (!nativeHeartbeat) {
      // Chrome's native port keeps this worker alive. Refresh the desktop's
      // verified receipt quietly, without interrupting an active media request.
      nativeHeartbeat = setInterval(() => {
        if (nativePort && pendingReplies.size === 0) checkConnection().catch(() => {});
      }, 30000);
      nativeHeartbeat.unref?.(); // Lets the Node transport tests finish normally.
    }
    return { connected: true, reviewAvailable: response.reviewAvailable === true, serviceVersion: response.serviceVersion, mediaPanelAvailable: response.mediaPanelAvailable === true };
  } catch (error) { return { connected: false, reviewAvailable: false, error: error.message }; }
}
async function currentTab(expectedPageURL = null) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || !tab.url || tab.incognito) throw new Error("Open a public webpage in a regular window, then open MVD Companion.");
  const pageURL = validatePublicURL(tab.url);
  if (expectedPageURL && pageURL !== validatePublicURL(expectedPageURL)) throw new Error("The current tab changed. Refresh the companion before sending a source.");
  return { tab, pageURL };
}
const FRAME_PREFIX = "playerFrame:";
function siteDomain(raw) { return new URL(validatePublicURL(raw)).hostname.toLowerCase().replace(/^www\./, ""); }
async function isSiteDisabled(raw) {
  const domain = siteDomain(raw), disabled = (await chrome.storage.local.get("disabledSites")).disabledSites || [];
  return disabled.some(site => domain === site || domain.endsWith("." + site));
}
async function disabledPatterns() {
  const disabled = (await chrome.storage.local.get("disabledSites")).disabledSites || [];
  return disabled.slice(0, 100).map(site => `*://${/^\d+\./.test(site) ? "" : "*."}${site}/*`);
}
async function frameContext(sender, expectedPageURL) {
  if (sender.id !== chrome.runtime.id || !sender.tab || !Number.isInteger(sender.tab.id) || !Number.isInteger(sender.frameId) || sender.frameId < 0 || sender.tab.incognito || ![undefined, "active"].includes(sender.documentLifecycle)) throw new Error("The player document is no longer active.");
  const tab = await chrome.tabs.get(sender.tab.id), pageURL = validatePublicURL(expectedPageURL), topPageURL = validatePublicURL(tab.url);
  // Chrome can retain the document's original sender URL after pushState.
  // The live frame URL and exact document ID below bind the current SPA route.
  if (new URL(validatePublicURL(sender.url)).origin !== new URL(pageURL).origin) throw new Error("The player page changed. Open its download button again.");
  if (!chrome.webNavigation?.getFrame) throw new Error("Reload MVD Companion and accept its navigation permission to enable player controls.");
  const frame = await chrome.webNavigation.getFrame({ tabId: tab.id, frameId: sender.frameId });
  if (!frame || validatePublicURL(frame.url) !== pageURL || !sender.documentId || frame.documentId !== sender.documentId) throw new Error("This video belongs to an old page. Open its download button again.");
  return { tabID: tab.id, frameID: sender.frameId, documentID: sender.documentId, pageURL, topPageURL, disabled: await isSiteDisabled(pageURL) || await isSiteDisabled(topPageURL) };
}
function validateFrameSnapshot(context, raw) {
  if (!raw || typeof raw !== "object" || JSON.stringify(raw).length > 256 * 1024) throw new Error("The page exposed too many player details.");
  if (validatePublicURL(raw.pageURL) !== context.pageURL) throw new Error("The player snapshot belongs to a different page. Open its download button again.");
}
async function saveFrameSnapshot(context, raw, preferredPlayerID = null) {
  validateFrameSnapshot(context, raw);
  const key = `${FRAME_PREFIX}${context.tabID}:${context.frameID}`;
  return serialized(key, async () => {
    const frame = await chrome.webNavigation.getFrame({ tabId: context.tabID, frameId: context.frameID });
    if (!frame || frame.documentId !== context.documentID || validatePublicURL(frame.url) !== context.pageURL) throw new Error("This video belongs to an old page. Open its download button again.");
    const previous = (await chrome.storage.session.get(key))[key];
    const registry = applySnapshot(previous, context.tabID, raw, context.documentID);
    registry.frameID = context.frameID; registry.topPageURL = context.topPageURL;
    compactRegistry(registry, 90 * 1024, preferredPlayerID);
    await chrome.storage.session.set({ [key]: registry });
    frameIndexQueue = frameIndexQueue.catch(() => {}).then(async () => {
      const prior = (await chrome.storage.session.get("playerFrameIndex")).playerFrameIndex || [];
      const index = [...prior.filter(item => item !== key), key];
      while (index.length > 24) await chrome.storage.session.remove(index.shift());
      await chrome.storage.session.set({ playerFrameIndex: index });
    });
    await frameIndexQueue;
    return registry;
  });
}
async function frameRegistry(context) {
  const key = `${FRAME_PREFIX}${context.tabID}:${context.frameID}`;
  const registry = (await chrome.storage.session.get(key))[key];
  if (!registry || registry.pageURL !== context.pageURL || registry.documentID !== context.documentID) throw new Error("Player details expired. Reopen its download button.");
  return registry;
}
async function toggleSite(raw, disabled) {
  const site = siteDomain(raw), previous = (await chrome.storage.local.get("disabledSites")).disabledSites || [];
  const disabledSites = disabled ? [...new Set([...previous, site])].slice(-100) : previous.filter(item => item !== site);
  await chrome.storage.local.set({ disabledSites });
  await syncContentScripts();
  for (const tab of await chrome.tabs.query({})) {
    if (tab.id === undefined) continue;
    const applies = tab.url ? await isSiteDisabled(tab.url).catch(() => false) : disabled;
    chrome.tabs.sendMessage(tab.id, { type: "siteState", disabled: applies }).catch(() => {});
    if (applies) clearTab(tab.id).catch(() => {});
  }
  return { disabled };
}
async function resolvePlayer(context, playerID, freshRegistry = null) {
  if (context.disabled) throw new Error("MVD is disabled on this website. Re-enable it from the extension popup.");
  const registry = freshRegistry || await frameRegistry(context), binding = playerMediaBinding(registry, playerID);
  const targets = [...new Set([binding.primaryTarget, ...binding.sourceTargets].filter(Boolean))].slice(0, 4);
  let target, response;
  for (let index = 0; index < targets.length; index += 1) {
    target = targets[index];
    const requestID = crypto.randomUUID();
    response = await nativeRequest({ protocolVersion: 1, requestID, command: "resolveMedia", url: target, sourcePageURL: context.pageURL, userGesture: true }, 110000);
    if (response.requestID !== requestID) throw new Error("The desktop response did not match this video.");
    if (!response.error) break;
    if (!unsupportedMediaPage(response.error)) throw new Error(response.error);
    if (index === targets.length - 1) throw new Error("MVD could not resolve this video page or find a playable source. Start the video, wait a moment, then reopen its download button. You can also try the video's original post.");
  }
  const mediaPreview = safeMediaPreview(response.mediaPreview), folders = safeFolders(response.folders), sessionToken = crypto.randomUUID();
  const session = { sessionToken, tabID: context.tabID, frameID: context.frameID, documentID: context.documentID, playerID, pageURL: context.pageURL, playerTarget: binding.primaryTarget, target, mediaPreview, folders, expiresAt: Date.now() + PANEL_TTL_MS };
  const existing = (await chrome.storage.session.get("mediaPanelSessions")).mediaPanelSessions || [];
  await chrome.storage.session.set({ mediaPanelSessions: [...existing.filter(item => item.expiresAt > Date.now()).slice(-7), session] });
  return { sessionToken, mediaPreview, folders, defaultFolderName: cleanPanelText(response.defaultFolderName || "Default MVD download folder"), previewTruncated: response.previewTruncated === true };
}
function cleanPanelText(raw) { return typeof raw === "string" ? raw.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 100) : "MVD folder"; }
async function enqueuePlayer(context, message, freshRegistry = null) {
  if (context.disabled) throw new Error("MVD is disabled on this website.");
  const sessions = (await chrome.storage.session.get("mediaPanelSessions")).mediaPanelSessions || [];
  const session = sessions.find(item => item.sessionToken === message.sessionToken);
  if (!session || session.expiresAt < Date.now() || session.tabID !== context.tabID || session.frameID !== context.frameID || session.documentID !== context.documentID || session.pageURL !== context.pageURL || session.playerID !== message.playerID) throw new Error("These video options expired. Open the player button again.");
  const binding = playerMediaBinding(freshRegistry || await frameRegistry(context), session.playerID);
  const expectedPrimaryTarget = Object.hasOwn(session, "playerTarget") ? session.playerTarget : session.target;
  if (binding.primaryTarget !== expectedPrimaryTarget || (session.target !== binding.primaryTarget && !binding.sourceTargets.includes(session.target))) throw new Error("The selected video changed. Resolve the player again.");
  const selection = validateSelection(session, message), signature = JSON.stringify(selection);
  if (session.acceptedJobID) return { accepted: true, jobID: session.acceptedJobID };
  if (session.pendingSignature && session.pendingSignature !== signature) throw new Error("The previous download is not confirmed. Retry its original options before changing them.");
  session.pendingSignature = signature;
  session.requestID ||= crypto.randomUUID(); session.idempotencyKey ||= crypto.randomUUID();
  await chrome.storage.session.set({ mediaPanelSessions: sessions });
  const result = await handoff({ protocolVersion: 1, requestID: session.requestID, command: "enqueueMedia", url: session.target, sourcePageURL: session.pageURL, userGesture: true, idempotencyKey: session.idempotencyKey, ...selection }, context.tabID);
  session.acceptedJobID = result.jobID; await chrome.storage.session.set({ mediaPanelSessions: sessions });
  return result;
}
async function handleContent(message, sender) {
  const context = await frameContext(sender, message.pageURL || message.snapshot?.pageURL);
  if (message.type === "overlayState") return { disabled: context.disabled };
  if (message.type === "disableSite") return toggleSite(context.topPageURL, message.disabled === true);
  if (context.disabled) throw new Error("MVD is disabled on this website.");
  if (message.type === "mediaObserved") {
    await saveFrameSnapshot(context, message.snapshot);
    if (context.frameID === 0) await acceptSnapshot(context.tabID, message.snapshot, context.documentID);
    return {};
  }
  if (message.type === "panelResolve" || message.type === "panelEnqueue") {
    // Resolve this command's own live snapshot, rather than re-reading storage
    // that a periodic inspection can replace while the user is choosing options.
    const registry = Object.hasOwn(message, "snapshot") ? await saveFrameSnapshot(context, message.snapshot, message.playerID) : null;
    return message.type === "panelResolve" ? resolvePlayer(context, message.playerID, registry) : enqueuePlayer(context, message, registry);
  }
  throw new Error("Unsupported player command.");
}

async function persistentPermission(raw) {
  const pattern = originPattern(raw);
  const permissions = await chrome.permissions.getAll();
  return (permissions.origins || []).some(granted => granted === pattern || granted === `${new URL(raw).protocol}//*/*` || granted === "*://*/*" || granted === "<all_urls>");
}
async function acceptSnapshot(tabID, raw, documentID) {
  return serialized(tabID, async () => {
    const frame = await chrome.webNavigation.getFrame({ tabId: tabID, frameId: 0 });
    if (!frame || validatePublicURL(frame.url) !== validatePublicURL(raw?.pageURL) || (documentID && frame.documentId !== documentID)) throw new Error("Stale page document.");
    const previous = await loadRegistry(tabID);
    const registry = applySnapshot(previous, tabID, raw, documentID);
    await saveRegistry(registry);
    return registry;
  });
}
async function inspectTab(tab, pageURL) {
  let warning = null;
  try {
    const files = ["player-context.js", "overlay-ui.js", "collector.js"];
    const results = await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, files, world: "ISOLATED" });
    const latest = await chrome.tabs.get(tab.id);
    if (validatePublicURL(latest.url) !== pageURL) throw new Error("The tab changed during collection.");
    for (const result of results) {
      if (!result.result?.pageURL || !result.documentId) continue;
      const frameID = result.frameId || 0;
      const frame = await chrome.webNavigation.getFrame({ tabId: tab.id, frameId: frameID });
      if (!frame || frame.documentId !== result.documentId || validatePublicURL(frame.url) !== validatePublicURL(result.result.pageURL)) continue;
      const context = { tabID: tab.id, frameID, documentID: result.documentId, pageURL: validatePublicURL(result.result.pageURL), topPageURL: pageURL };
      if (await isSiteDisabled(pageURL) || await isSiteDisabled(context.pageURL)) continue;
      await saveFrameSnapshot(context, result.result);
      if (frameID === 0) await acceptSnapshot(tab.id, result.result, result.documentId);
    }
    // A cross-origin iframe may need its own optional grant. Its failure must
    // never turn a successful main-frame inspection into a page-wide warning.
    const frames = chrome.webNavigation.getAllFrames ? await chrome.webNavigation.getAllFrames({ tabId: tab.id }).catch(() => []) || [] : [];
    for (const frame of frames.filter(item => item.frameId !== 0).slice(0, 16)) {
      try {
        const frameURL = validatePublicURL(frame.url);
        if (new URL(frameURL).origin !== new URL(pageURL).origin && !(await persistentPermission(frameURL))) continue;
        await chrome.scripting.executeScript({ target: { tabId: tab.id, frameIds: [frame.frameId] }, files, world: "ISOLATED" });
      } catch { /* The popup can request an observed iframe host explicitly. */ }
    }
  } catch { warning = "Chrome could not inspect this page. Reopen the companion to grant active-tab access, or enable this site below."; }
  let registry = await loadRegistry(tab.id);
  if (!registry || registry.pageURL !== pageURL) registry = freshRegistry(tab.id, pageURL, tab.title);
  const sitePermission = await persistentPermission(pageURL);
  return { ...registrySnapshot(registry), sitePermission, warning, disabled: await isSiteDisabled(pageURL) };
}
async function inspectCurrentPage() { const { tab, pageURL } = await currentTab(); return inspectTab(tab, pageURL); }
async function snapshotCurrentPage() {
  const { tab, pageURL } = await currentTab();
  const registry = await loadRegistry(tab.id);
  if (!registry || registry.pageURL !== pageURL) return inspectTab(tab, pageURL);
  return { ...registrySnapshot(registry), sitePermission: await persistentPermission(pageURL), disabled: await isSiteDisabled(pageURL) };
}
function syncContentScripts() {
  contentScriptQueue = contentScriptQueue.catch(() => {}).then(performContentScriptSync);
  return contentScriptQueue;
}
async function performContentScriptSync() {
  await installNetworkObserver();
  const permissions = await chrome.permissions.getAll();
  const matches = [...new Set((permissions.origins || []).filter(pattern => {
    try { return (["http://*/*", "https://*/*", "*://*/*"].includes(pattern) || /^https?:\/\/[^/*]+\/\*$/.test(pattern)) && (["http://*/*", "https://*/*", "*://*/*"].includes(pattern) || originPattern(pattern.slice(0, -1)) === pattern); } catch { return false; }
  }))].slice(0, 100);
  await chrome.scripting.unregisterContentScripts({ ids: ["harbor-approved-media"] }).catch(() => {});
  if (matches.length) await chrome.scripting.registerContentScripts([{ id: "harbor-approved-media", matches, excludeMatches: await disabledPatterns(), js: ["player-context.js", "overlay-ui.js", "collector.js"], runAt: "document_idle", allFrames: true, persistAcrossSessions: true }]);
}
async function handlePopup(message) {
  if (message?.type === "inspect") return inspectCurrentPage();
  if (message?.type === "snapshot") return snapshotCurrentPage();
  if (message?.type === "connection") return checkConnection();
  if (message?.type === "state") return chrome.storage.session.get([OUTBOX_KEY, "lastResult"]);
  if (message?.type === "toggleSite") { const { pageURL } = await currentTab(message.sourcePageURL); await toggleSite(pageURL, message.disabled === true); return inspectCurrentPage(); }
  if (message?.type === "showPlayerPanel") { const { tab } = await currentTab(message.sourcePageURL); const result = await chrome.tabs.sendMessage(tab.id, { type: "showPlayerPanel", playerID: message.playerID || null }, { frameId: Number.isInteger(message.frameID) ? message.frameID : 0 }); if (!result?.opened) throw new Error(result?.error || "Play a video, then use its MVD download button."); return { opened: true }; }
  if (message?.type === "permissionsChanged") { await syncContentScripts(); return inspectCurrentPage(); }
  if (message?.type === "retry") {
    const pending = (await chrome.storage.session.get(OUTBOX_KEY))[OUTBOX_KEY];
    if (!pending) throw new Error("There is no pending download to retry.");
    return handoff(pending, pending.tabID);
  }
  if (["enqueue", "openReview"].includes(message?.type)) {
    const { tab, pageURL } = await currentTab(message.sourcePageURL);
    const url = validatePublicURL(message.url);
    const registry = await loadRegistry(tab.id);
    const candidate = registry?.pageURL === pageURL ? registrySnapshot(registry).candidates.find(item => item.url === url) : null;
    if (candidate?.protected) throw new Error("Protected playback is unavailable. No download or review was sent.");
    if (message.type === "openReview") return openReview(url, pageURL, tab.id);
    return handoff({ protocolVersion: 1, requestID: crypto.randomUUID(), command: "enqueue", url, sourcePageURL: pageURL, idempotencyKey: crypto.randomUUID(), userGesture: true }, tab.id);
  }
  throw new Error("Unsupported companion command.");
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id) return false;
  if (sender.tab && ["mediaObserved", "overlayState", "panelResolve", "panelEnqueue", "disableSite"].includes(message?.type)) {
    handleContent(message, sender).then(result => sendResponse({ ok: true, ...result })).catch(error => sendResponse({ ok: false, error: error.message || "The player action failed." }));
    return true;
  }
  if (sender.url !== chrome.runtime.getURL("popup.html") || sender.tab) return false;
  handlePopup(message).then(result => sendResponse({ ok: true, ...result })).catch(error => sendResponse({ ok: false, error: error.message || "The companion could not complete this action." }));
  return true;
});

function scheduleInspection(tabID) {
  clearTimeout(scanTimers.get(tabID));
  scanTimers.set(tabID, setTimeout(async () => {
    scanTimers.delete(tabID);
    try {
      const tab = await chrome.tabs.get(tabID);
      if (!tab.url || tab.incognito) return;
      const pageURL = validatePublicURL(tab.url);
      if (await persistentPermission(pageURL)) await inspectTab(tab, pageURL);
      else { const existing = await loadRegistry(tabID); if (existing?.pageURL === pageURL) await badge(tabID, existing); }
    } catch { await badge(tabID).catch(() => {}); }
  }, 150));
}
chrome.tabs.onUpdated.addListener((tabID, change) => {
  if (change.status === "loading" || change.url) clearTab(tabID).catch(() => {});
  if (change.status === "complete" || change.url) scheduleInspection(tabID);
});
chrome.tabs.onActivated.addListener(({ tabId }) => scheduleInspection(tabId));
chrome.tabs.onRemoved.addListener(tabID => {
  clearTimeout(scanTimers.get(tabID)); scanTimers.delete(tabID);
  chrome.storage.session.remove(REGISTRY_PREFIX + tabID).catch(() => {});
});
for (const event of [chrome.webNavigation?.onCommitted, chrome.webNavigation?.onHistoryStateUpdated, chrome.webNavigation?.onReferenceFragmentUpdated].filter(Boolean)) {
  event.addListener(details => {
    if (details.frameId !== 0) return;
    clearTab(details.tabId).catch(() => {});
    scheduleInspection(details.tabId);
  });
}
chrome.permissions.onAdded.addListener(() => { syncContentScripts().catch(() => {}); installNetworkObserver().catch(() => {}); });
chrome.permissions.onRemoved.addListener(() => {
  syncContentScripts().catch(() => {});
  chrome.tabs.query({}).then(tabs => { for (const tab of tabs) { clearTab(tab.id).catch(() => {}); scheduleInspection(tab.id); } }).catch(() => {});
});

function observeNetworkHeaders(details) {
  (async () => {
    if (details.tabId < 0 || details.frameId !== 0 || details.statusCode < 200 || details.statusCode >= 300) return;
    const mime = details.responseHeaders?.find(header => header.name.toLowerCase() === "content-type")?.value || "";
    if (!isNetworkMedia(details.url, mime, details.type)) return;
    const tab = await chrome.tabs.get(details.tabId);
    if (!tab.url || tab.incognito) return;
    const pageURL = validatePublicURL(tab.url);
    if (await isSiteDisabled(pageURL)) return;
    const frame = await chrome.webNavigation.getFrame({ tabId: details.tabId, frameId: 0 });
    if (!frame || validatePublicURL(frame.url) !== pageURL || !details.documentId || frame.documentId !== details.documentId) return;
    if (details.initiator && new URL(details.initiator).origin !== new URL(pageURL).origin) return;
    if (!(await persistentPermission(pageURL)) || !(await persistentPermission(details.url))) return;
    await serialized(tab.id, async () => {
      const previous = await loadRegistry(tab.id);
      if (previous?.documentID && details.documentId && previous.documentID !== details.documentId) return;
      const registry = applyNetworkObservation(previous, tab.id, pageURL, { url: details.url, mime, requestType: details.type, documentID: details.documentId }, tab.title);
      if (!registry.documentID && details.documentId) registry.documentID = details.documentId;
      await saveRegistry(registry);
    });
  })().catch(() => {});
}
let networkObserverInstalled = false;
async function installNetworkObserver() {
  if (networkObserverInstalled || !chrome.webRequest?.onHeadersReceived) return;
  const grants = await chrome.permissions.getAll();
  if (!(grants.origins || []).some(origin => /^https?:\/\//.test(origin))) return;
  try {
    chrome.webRequest.onHeadersReceived.addListener(observeNetworkHeaders, { urls: ["http://*/*", "https://*/*"], types: ["media", "xmlhttprequest", "other"] }, ["responseHeaders"]);
    networkObserverInstalled = true;
  } catch { /* Host access is optional; native handoff and DOM inspection stay available. */ }
}
installNetworkObserver().catch(() => {});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "harbor-link", title: "Send link to MVD", contexts: ["link"], documentUrlPatterns: ["http://*/*", "https://*/*"] });
    chrome.contextMenus.create({ id: "harbor-page", title: "Review in MVD", contexts: ["page", "video", "audio"], documentUrlPatterns: ["http://*/*", "https://*/*"] });
  });
  syncContentScripts().catch(() => {});
  checkConnection().catch(() => {});
});
chrome.runtime.onStartup.addListener(() => {
  syncContentScripts().catch(() => {});
  checkConnection().catch(() => {});
});
chrome.contextMenus.onClicked.addListener((info, tab) => {
  (async () => {
    if (!tab?.url || tab.incognito) throw new Error("Only regular public webpages are supported.");
    const pageURL = validatePublicURL(tab.url);
    const url = validatePublicURL(info.menuItemId === "harbor-link" ? info.linkUrl : (info.srcUrl?.startsWith("http") ? info.srcUrl : pageURL));
    if (info.menuItemId === "harbor-link" && isDirectDownloadURL(url)) await handoff({ protocolVersion: 1, requestID: crypto.randomUUID(), command: "enqueue", url, sourcePageURL: pageURL, idempotencyKey: crypto.randomUUID(), userGesture: true }, tab.id);
    else await openReview(url, pageURL, tab.id);
  })().catch(error => setResult({ message: error.message || "Open the companion to repair its desktop connection.", failed: true, tabID: tab?.id }));
});
