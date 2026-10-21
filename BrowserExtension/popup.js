import { isDirectDownloadURL, originPattern, safeThumbnail, validatePublicURL } from "./core.js";

const ids = ["page-title", "page-host", "availability", "badge-preview", "connection-status", "reconnect", "send-page", "review-page", "link-form", "link-url", "review-url", "count", "candidates", "empty", "retry", "refresh", "status", "permission-status", "enable-site", "cdn-controls", "cdn-origin", "enable-cdn", "enable-all", "toggle-site"];
const elements = Object.fromEntries(ids.map(id => [id, document.getElementById(id)]));
let page = null;
let busy = false;
let refreshTimer;
function status(message, failed = false) { elements.status.textContent = message; elements.status.dataset.error = String(failed); }
async function send(message) {
  const response = await chrome.runtime.sendMessage(message);
  if (!response?.ok) throw new Error(response?.error || "MVD Companion is unavailable. Reopen this popup.");
  return response;
}
function setBusy(value) {
  busy = value;
  document.querySelectorAll("button[data-source-action]").forEach(button => { button.disabled = value || button.dataset.unavailable === "true"; });
  elements["send-page"].disabled = value || !page || page.disabled;
  elements["review-page"].disabled = value || !page || page.disabled;
  elements["review-url"].disabled = value || !page;
  elements.retry.disabled = value;
}
async function takeAction(url, action, retry = false) {
  if (busy) return;
  if (!page) { status("Open a public website in this tab before sending a link to MVD.", true); return; }
  setBusy(true);
  status(action === "openReview" ? "Opening the review composer in MVD…" : "Waiting for durable download confirmation…");
  try {
    const response = await send(retry ? { type: "retry" } : { type: action, url, sourcePageURL: page.pageURL });
    if (response.opened === true && action === "showPlayerPanel") status("Video options opened on this page. Choose its format and destination there.");
    else if (response.opened === true) status("Review opened in MVD. Click Review Link there, choose a quality, then Download. No download was queued by this action.");
    else if (response.accepted === true && response.jobID) { status(`Download accepted · job ${response.jobID.slice(0, 8)}. View progress in MVD.`); elements.retry.hidden = true; }
    else throw new Error("MVD did not confirm the requested action.");
  } catch (error) {
    status(error.message, true);
    const state = await send({ type: "state" }).catch(() => ({}));
    elements.retry.hidden = !state.pendingHandoff;
  } finally { setBusy(false); }
}
function sourceRow(candidate, index) {
  const item = document.createElement("li");
  const thumbnail = document.createElement("div"); thumbnail.className = "thumbnail";
  const placeholder = document.createElement("span"); placeholder.className = `placeholder${candidate.isMedia ? "" : " file-placeholder"}`; placeholder.textContent = candidate.isMedia ? "Video" : "File"; thumbnail.append(placeholder);
  thumbnail.title = candidate.thumbnailSource;
  const imageURL = safeThumbnail(candidate.thumbnailURL, page.pageURL);
  if (imageURL) {
    const image = document.createElement("img"); image.alt = candidate.thumbnailSource; image.loading = "lazy"; image.decoding = "async"; image.crossOrigin = "anonymous"; image.referrerPolicy = "no-referrer";
    image.addEventListener("load", () => placeholder.remove());
    image.addEventListener("error", () => image.remove());
    image.src = imageURL; thumbnail.prepend(image);
  }
  const number = document.createElement("span"); number.className = "source-number"; number.textContent = String(index + 1); thumbnail.append(number);
  const info = document.createElement("div"); info.className = "source-info";
  const title = document.createElement("span"); title.className = "source-title"; title.textContent = candidate.title; title.title = `${candidate.title} · ${candidate.titleSource}`;
  const meta = document.createElement("span"); meta.className = "source-meta"; meta.textContent = `${candidate.mediaType}${candidate.variants.length > 1 ? ` · ${candidate.variants.length} source links` : ""}`;
  const source = document.createElement("span"); source.className = "source-meta"; source.textContent = candidate.sourceLabel; source.title = `${candidate.sourceLabel} · ${candidate.discovery}`;
  info.append(title, meta, source);
  if (candidate.title !== page.title) { const pageTitle = document.createElement("span"); pageTitle.className = "source-page"; pageTitle.textContent = `Page: ${page.title}`; info.append(pageTitle); }
  if (candidate.protected) { const unavailable = document.createElement("span"); unavailable.className = "source-caption protected"; unavailable.textContent = "Protected playback · unavailable"; info.append(unavailable); }
  else {
    const button = document.createElement("button"); button.dataset.sourceAction = "true";
    const action = candidate.isMedia ? "showPlayerPanel" : "enqueue";
    button.textContent = candidate.isMedia ? "Video options" : "Download file";
    button.setAttribute("aria-label", `${button.textContent}: ${candidate.title}`);
    button.disabled = busy || page.disabled || !candidate.usable;
    button.dataset.unavailable = String(page.disabled || !candidate.usable);
    button.addEventListener("click", () => { if (candidate.isMedia) send({ type: "showPlayerPanel", sourcePageURL: page.pageURL, playerID: candidate.assetID, frameID: candidate.frameID || 0 }).then(() => status("Video options opened on this page.")).catch(error => status(error.message, true)); else takeAction(candidate.url, action); }); info.append(button);
  }
  item.append(thumbnail, info); return item;
}
function renderPage(next) {
  page = next;
  elements["page-title"].textContent = page.title;
  elements["page-host"].textContent = new URL(page.pageURL).hostname;
  elements["badge-preview"].textContent = String(page.usableMediaCount);
  elements.count.textContent = `${page.candidates.length} source${page.candidates.length === 1 ? "" : "s"}`;
  elements["send-page"].textContent = isDirectDownloadURL(page.pageURL) ? "Download this file" : "Choose video options";
  elements["send-page"].disabled = busy || page.disabled;
  elements["review-page"].disabled = busy || page.disabled;
  elements["review-url"].disabled = busy;
  elements["toggle-site"].disabled = false;
  elements["toggle-site"].textContent = page.disabled ? "Re-enable on this website" : "Disable on this website";
  elements.empty.hidden = page.candidates.some(candidate => candidate.usable);
  let availability = page.usableMediaCount ? `${page.usableMediaCount} video source${page.usableMediaCount === 1 ? " is" : "s are"} ready. Choose a video below or open its download options.` : "No downloadable video detected yet. Start playback, then refresh.";
  if (page.protectedMedia) availability += " Protected playback is unavailable.";
  if (page.inaccessibleMedia) availability += " Some players expose browser-only blob URLs; optional network detection may reveal a public manifest.";
  if (page.warning) availability = page.warning;
  if (page.disabled) availability = "MVD is disabled on this website. Re-enable it below to show player buttons.";
  elements.availability.textContent = availability;
  elements.candidates.replaceChildren(...page.candidates.map(sourceRow));
  elements["permission-status"].textContent = page.sitePermission ? "Automatic detection is enabled on this site. Other media hosts need their own optional permission." : "This popup checks the current page. Allow this site to keep numbered badges updated automatically on later visits.";
  elements["enable-site"].disabled = Boolean(page.sitePermission);
  elements["enable-site"].textContent = page.sitePermission ? "Automatic site detection enabled" : "Enable automatic detection on this site";
  const currentOrigin = new URL(page.pageURL).origin;
  const origins = [...new Set([...page.candidates.map(candidate => new URL(candidate.url).origin), ...(page.frameOrigins || [])].filter(origin => origin !== currentOrigin))].slice(0, 12);
  const previous = elements["cdn-origin"].value;
  elements["cdn-origin"].replaceChildren(...origins.map(origin => { const option = document.createElement("option"); option.value = origin; option.textContent = origin; return option; }));
  if (origins.includes(previous)) elements["cdn-origin"].value = previous;
  elements["cdn-controls"].hidden = origins.length === 0;
}
async function refresh(inspect = false) {
  try { renderPage(await send({ type: inspect ? "inspect" : "snapshot" })); }
  catch (error) {
    page = null; elements["page-title"].textContent = "This page is unavailable"; elements["page-host"].textContent = ""; elements["badge-preview"].textContent = "—"; elements.availability.textContent = error.message;
    elements["send-page"].disabled = true; elements["review-page"].disabled = true; elements["review-url"].disabled = true; elements["enable-site"].disabled = true; elements["toggle-site"].disabled = true; elements.candidates.replaceChildren(); elements["cdn-controls"].hidden = true;
  }
}
async function connection() {
  elements["connection-status"].textContent = "Checking MVD…";
  elements["connection-status"].dataset.connected = "false";
  elements["connection-status"].dataset.error = "false";
  elements.reconnect.disabled = true;
  const result = await send({ type: "connection" }).catch(error => ({ connected: false, error: error.message }));
  elements["connection-status"].textContent = result.connected ? result.reviewAvailable ? "MVD connected" : "MVD connected · review unavailable" : "MVD unavailable · check setup";
  elements["connection-status"].dataset.connected = String(result.connected === true);
  elements["connection-status"].dataset.error = String(!result.connected);
  elements["connection-status"].title = result.error || `Service ${result.serviceVersion || ""}`;
  elements.reconnect.disabled = false;
}
async function afterPermission(granted) {
  if (!granted) { status("Permission was not granted. Current-page DOM inspection still works when you open the companion.", true); return; }
  renderPage(await send({ type: "permissionsChanged" }));
  status("Detection permission saved. Play the video again to observe new media requests.");
}
// permissions.request is invoked directly inside each click gesture, before any await.
elements["enable-site"].addEventListener("click", () => {
  if (!page) return;
  chrome.permissions.request({ origins: [originPattern(page.pageURL)] }).then(afterPermission).catch(error => status(error.message, true));
});
elements["enable-cdn"].addEventListener("click", () => {
  if (!page || !elements["cdn-origin"].value) return;
  chrome.permissions.request({ origins: [originPattern(page.pageURL), originPattern(elements["cdn-origin"].value)] }).then(afterPermission).catch(error => status(error.message, true));
});
elements["send-page"].addEventListener("click", () => takeAction(page.pageURL, isDirectDownloadURL(page.pageURL) ? "enqueue" : "showPlayerPanel"));
elements["review-page"].addEventListener("click", () => takeAction(page?.pageURL, "openReview"));
elements["link-form"].addEventListener("submit", event => {
  event.preventDefault();
  if (busy) return;
  try { takeAction(validatePublicURL(elements["link-url"].value.trim()), "openReview"); }
  catch (error) { status(error.message, true); elements["link-url"].focus(); }
});
elements.retry.addEventListener("click", () => takeAction(null, "enqueue", true));
elements.refresh.addEventListener("click", () => refresh(true));
elements.reconnect.addEventListener("click", connection);
chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.id === chrome.runtime.id && message?.type === "registryChanged" && page?.tabID === message.tabID) { clearTimeout(refreshTimer); refreshTimer = setTimeout(() => refresh(), 150); }
});
elements["enable-all"].addEventListener("click", () => { chrome.permissions.request({ origins: ["http://*/*", "https://*/*"] }).then(afterPermission).catch(error => status(error.message, true)); });
elements["toggle-site"].addEventListener("click", () => { if (!page) return; send({ type: "toggleSite", sourcePageURL: page.pageURL, disabled: !page.disabled }).then(renderPage).catch(error => status(error.message, true)); });
async function initialize() {
  await refresh(true);
  const state = await send({ type: "state" });
  elements.retry.hidden = !state.pendingHandoff;
  if (state.lastResult && state.lastResult.tabID === page?.tabID) status(state.lastResult.message, state.lastResult.failed);
  connection();
}
initialize().catch(error => status(error.message, true));
