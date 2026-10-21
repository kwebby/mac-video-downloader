import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
const script = await readFile(new URL("../collector.js", import.meta.url), "utf8");
const playerContextScript = await readFile(new URL("../player-context.js", import.meta.url), "utf8");
function fixture() {
  const listeners = new Map(), timers = [], intervals = [];
  class MediaElement {}
  const video = Object.assign(new MediaElement(), { currentSrc: "blob:https://public-site.com/player", src: "", poster: "https://cdn.public-site.com/film-poster.jpg", title: "Film A", mediaKeys: null, getAttribute() { return null; }, closest() { return null; }, querySelectorAll() { return [{ src: "https://cdn.public-site.com/master.m3u8?signature=a%2Fb", type: "application/vnd.apple.mpegurl" }]; } });
  const second = Object.assign(new MediaElement(), { currentSrc: "https://cdn.public-site.com/second.mp4", src: "", poster: "", title: "", mediaKeys: null, getAttribute() { return null; }, closest() { return { querySelector() { return { textContent: "A nearby caption" }; } }; }, querySelectorAll() { return []; } });
  const context = { URL, location: { href: "https://public-site.com/watch" }, HTMLMediaElement: MediaElement,
    document: { title: "Page title", documentElement: {}, querySelector(selector) { return selector.includes("og:image") ? { content: "https://public-site.com/page-poster.jpg" } : null; }, querySelectorAll(selector) { return selector === "video, audio" ? [video, second] : [{ href: "https://public-site.com/guide.pdf", textContent: "Guide" }]; }, addEventListener(name, handler) { listeners.set(name, handler); } },
    window: { addEventListener(name, handler) { listeners.set(name, handler); } },
    MutationObserver: class { constructor(handler) { this.handler = handler; } observe() {} }, PerformanceObserver: class { observe() {} },
    performance: { getEntriesByType() { return [{ name: "https://cdn.public-site.com/segment-1.m4s" }]; } },
    chrome: { runtime: { async sendMessage() { return { ok: true, disabled: false }; } } },
    setTimeout(callback) { timers.push(callback); return timers.length; }, clearTimeout() {}, setInterval(callback) { intervals.push(callback); }
  };
  context.globalThis = context;
  vm.createContext(context);
  return { context, video, second, listeners, timers, intervals };
}
test("packaged observer extracts separate video/poster/caption metadata and keeps blob sources unavailable", () => {
  const page = fixture();
  const result = vm.runInContext(script, page.context);
  assert.equal(result.players.length, 2); assert.equal(result.inaccessibleMedia, 1);
  const manifest = result.observations.find(item => item.url.includes("master.m3u8"));
  assert.equal(manifest.url, "https://cdn.public-site.com/master.m3u8?signature=a%2Fb");
  assert.equal(manifest.title, "Film A"); assert.equal(manifest.titleSource, "Video title"); assert.equal(manifest.thumbnailSource, "Video poster");
  assert.equal(result.players[1].title, "A nearby caption"); assert.equal(result.players[1].thumbnailSource, "Page image fallback");
  assert.equal(result.observations.some(item => item.url.startsWith("blob:")), false);
  vm.runInContext(script, page.context); assert.equal(page.intervals.length, 1, "reopening popup must reuse the existing observer");
});
test("encrypted playback evidence persists and SPA URL checks schedule a new snapshot", async () => {
  const page = fixture(); vm.runInContext(script, page.context);
  page.listeners.get("encrypted")({ target: page.video });
  assert.equal(page.context.__harborMediaObserver.snapshot().protectedMedia, 1);
  assert.equal(page.context.__harborMediaObserver.snapshot().players[0].protected, true);
  const before = page.timers.length; page.context.location.href = "https://public-site.com/next"; page.intervals[0](); await new Promise(resolve => setTimeout(resolve, 0));
  assert.ok(page.timers.length > before); assert.equal(page.context.__harborMediaObserver.snapshot().pageURL, "https://public-site.com/next");
});
test("a clicked reel survives preloaded-player limits and oversized posters in its own command snapshot", async () => {
  const page = fixture(), opened = [], sent = [], buttons = new Map();
  page.context.location.href = "https://www.instagram.com/reels/DeZtDYYNCWf/";
  const media = Array.from({ length: 110 }, (_, index) => ({
    tagName: "VIDEO", isConnected: true, currentSrc: "blob:https://www.instagram.com/player", src: "", readyState: 4,
    paused: true, ended: false, mediaKeys: null, title: `Reel ${index}`, poster: `https://cdn.public-site.com/${"p".repeat(8100)}-${index}.jpg`,
    getAttribute() { return null; }, closest() { return null; }, querySelectorAll() { return []; },
    getBoundingClientRect() { return { left: 100, right: 740, top: index === 109 ? 100 : 1000, bottom: index === 109 ? 460 : 1360, width: 640, height: 360 }; }
  }));
  const selected = media.at(-1);
  page.context.document.querySelectorAll = selector => selector === "video, audio" || selector === "video" ? media : [];
  page.context.getComputedStyle = () => ({ display: "block", visibility: "visible", opacity: "1" });
  page.context.__MVDPlayerContext = {
    isAd: () => false, visiblePlaying: element => element === selected,
    targetFor: element => element === selected ? page.context.location.href : null,
    providerURL: url => url
  };
  page.context.__MVDOverlayUI = {
    trigger(open, title) { buttons.set(title, open); return { move() {}, setVisible() {}, remove() {} }; },
    panel(options) { opened.push(options); return { remove() {} }; }
  };
  page.context.chrome.runtime.sendMessage = async message => { sent.push(message); return { ok: true, disabled: false }; };
  vm.runInContext(script, page.context);
  await new Promise(resolve => setTimeout(resolve, 0));
  const observed = page.context.__harborMediaObserver.snapshot();
  assert.equal(observed.players.length, 80);
  assert.equal(observed.players[0].title, "Reel 109");
  assert.equal(observed.players[0].targetURL, page.context.location.href);
  assert.ok(JSON.stringify(observed).length <= 220 * 1024);
  assert.equal(observed.players[0].thumbnailURL, "", "large posters must not evict player identities");
  assert.ok(buttons.has("Reel 109"), "visible reel beyond the DOM-order cap gets a button");
  await buttons.get("Reel 109")();
  await opened[0].resolve();
  const request = sent.find(message => message.type === "panelResolve");
  assert.ok(request?.snapshot, "a panel command carries its own freshly collected evidence");
  assert.equal(request.snapshot.players[0].assetID, request.playerID);
  assert.equal(request.snapshot.players[0].targetURL, page.context.location.href);
  assert.ok(JSON.stringify(request).length < 256 * 1024);
  await opened[0].enqueue({ sessionToken: "test-session", options: { mode: "audioOnly" } });
  const enqueue = sent.find(message => message.type === "panelEnqueue");
  assert.equal(enqueue.snapshot.players[0].assetID, enqueue.playerID);
});
test("LinkedIn snapshots bind complete configured and resource sources only to their matching player", () => {
  const page = fixture(), asset = "D4D05AQExampleAsset01", otherAsset = "D4D05AQDifferentAsset2";
  const progressive = `https://dms.licdn.com/playlist/vid/v2/${asset}/mp4-720p-30fp-crf28/0/1787692043117?token=a%2Fb`;
  const otherProgressive = `https://dms.licdn.com/playlist/vid/v2/${otherAsset}/mp4-720p-30fp-crf28/0/1792500067911`;
  const manifest = "https://dms.licdn.com/current-master.m3u8?token=c%2Fd";
  page.context.location.href = "https://www.linkedin.com/feed/";
  page.video.currentSrc = "blob:https://www.linkedin.com/one"; page.second.currentSrc = "blob:https://www.linkedin.com/two";
  const firstPoster = `https://media.licdn.com/dms/image/v2/${asset}/videocover-low/0/12345?token=poster%2Fsignature`;
  page.video.poster = "";
  const posterNode = { style: { backgroundImage: `url("${firstPoster}")` } };
  page.video.parentElement = { className: "video-js", hasAttribute(name) { return name === "data-vjs-player"; }, querySelectorAll(selector) { return selector === "video" ? [page.video] : selector.includes("background-image") ? [posterNode] : []; } };
  page.second.poster = `https://media.licdn.com/dms/image/v2/${otherAsset}/videocover-high/0/54321`;
  page.video.querySelectorAll = page.second.querySelectorAll = () => [];
  page.video.closest = page.second.closest = () => null;
  page.video.getAttribute = name => name === "data-sources" ? JSON.stringify([{ src: manifest, type: "application/vnd.apple.mpegurl" }]) : null;
  page.second.getAttribute = () => null;
  page.context.performance.getEntriesByType = () => [{ name: progressive }, { name: otherProgressive }, { name: `https://dms.licdn.com/playlist/vid/v2/${asset}/dash-720p/0/12345` }];
  page.context.document.querySelectorAll = selector => ["video, audio", "video"].includes(selector) ? [page.video, page.second] : [];
  vm.runInContext(playerContextScript, page.context);
  const snapshot = vm.runInContext(script, page.context);
  const [first, second] = snapshot.players;
  assert.equal(first.targetURL, manifest); assert.equal(second.targetURL, otherProgressive);
  assert.equal(first.thumbnailURL, firstPoster); assert.equal(first.thumbnailSource, "Nearby player poster");
  const own = snapshot.observations.filter(item => item.assetID === first.assetID);
  assert.equal(own.some(item => item.url === progressive && item.mime === "video/mp4"), true);
  assert.equal(own.some(item => item.url === manifest), true);
  assert.equal(own.some(item => item.url === otherProgressive), false);
  assert.equal(own.some(item => item.url.includes("dash-720p")), false);
  assert.equal(snapshot.observations.some(item => item.assetID === second.assetID && item.url === otherProgressive), true);
  assert.equal(snapshot.inaccessibleMedia, 0, "a blob with an evidenced complete source is resolvable");
});
