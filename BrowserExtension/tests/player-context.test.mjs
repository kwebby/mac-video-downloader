import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
const sandbox = { URL, innerWidth: 1200, innerHeight: 800 }; vm.createContext(sandbox);
vm.runInContext(await readFile(new URL("../player-context.js", import.meta.url), "utf8"), sandbox);
const api = sandbox.__MVDPlayerContext;
const video = overrides => ({ currentSrc: "blob:https://www.youtube.com/player", src: "", readyState: 4, paused: true, ended: true, mediaKeys: null, closest() { return null; }, querySelectorAll() { return []; }, ...overrides });
test("YouTube watch, shorts and embedded players resolve to the associated provider video page", () => {
  assert.equal(api.targetFor(video(), "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=ignore", 3), "https://www.youtube.com/watch?v=aqz-KE-bpKQ");
  assert.equal(api.targetFor(video(), "https://www.youtube.com/shorts/aqz-KE-bpKQ", 1), "https://www.youtube.com/watch?v=aqz-KE-bpKQ");
  assert.equal(api.targetFor(video(), "https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ", 1), "https://www.youtube.com/watch?v=aqz-KE-bpKQ");
  const card = video({ closest(selector) { return selector.includes("ytd-rich") ? { querySelector() { return { href: "https://www.youtube.com/watch?v=dQw4w9WgXc" }; } } : null; } });
  assert.equal(api.targetFor(card, "https://www.youtube.com/", 8), "https://www.youtube.com/watch?v=dQw4w9WgXc");
});
test("multiple unrelated opaque players never receive a guessed shared page target", () => {
  assert.equal(api.targetFor(video(), "https://public-site.com/multiple", 2), null);
  assert.equal(api.targetFor(video(), "https://public-site.com/one", 1), "https://public-site.com/one");
  assert.equal(api.targetFor(video({ currentSrc: "https://cdn.public-site.com/film.mp4?signature=a%2Fb" }), "https://public-site.com/multiple", 2), "https://cdn.public-site.com/film.mp4?signature=a%2Fb");
});
test("loaded paused and ended videos retain their button, while ads, DRM and hidden players do not", () => {
  const rect = { width: 640, height: 360, top: 100, bottom: 460, left: 100, right: 740 }, style = { display: "block", visibility: "visible", opacity: "1" };
  assert.equal(api.visiblePlaying(video(), rect, style), true);
  assert.equal(api.visiblePlaying(video({ readyState: 0 }), rect, style), false);
  assert.equal(api.visiblePlaying(video({ mediaKeys: {} }), rect, style), false);
  assert.equal(api.visiblePlaying(video({ closest() { return {}; } }), rect, style), false);
  assert.equal(api.visiblePlaying(video(), rect, { ...style, visibility: "hidden" }), false);
});
function feedPlayers(rectangles) {
  const elements = rectangles.map(rect => video({ isConnected: true, getBoundingClientRect() { return rect; } }));
  const document = { querySelectorAll() { return elements; }, defaultView: { getComputedStyle() { return { display: "block", visibility: "visible", opacity: "1" }; } } };
  for (const element of elements) element.ownerDocument = document;
  return elements;
}
test("Instagram reel permalink belongs only to its dominant visible player despite preloaded siblings", () => {
  const currentURL = "https://www.instagram.com/reels/DeZtDYYNCWf/";
  const main = { left: 300, right: 700, top: 60, bottom: 780, width: 400, height: 720 };
  const outside = { left: 300, right: 700, top: 900, bottom: 1620, width: 400, height: 720 };
  const players = feedPlayers([outside, outside, main, outside, outside, outside]);
  assert.equal(api.providerURL(currentURL), currentURL);
  assert.equal(api.targetFor(players[2], currentURL, 6), currentURL);
  for (const player of players.filter(item => item !== players[2])) assert.equal(api.targetFor(player, currentURL, 6), null);
});
test("equally visible opaque reels need their own associated card permalink", () => {
  const rect = { left: 100, right: 500, top: 100, bottom: 600, width: 400, height: 500 };
  const [first, second] = feedPlayers([rect, { ...rect, left: 600, right: 1000 }]);
  const currentURL = "https://www.instagram.com/reels/DeZtDYYNCWf/";
  assert.equal(api.targetFor(first, currentURL, 2), null); assert.equal(api.targetFor(second, currentURL, 2), null);
  first.parentElement = { parentElement: null, querySelectorAll(selector) { return selector === "video" ? [first] : [{ href: "/reel/DistinctA1/" }]; } };
  second.parentElement = { parentElement: null, querySelectorAll(selector) { return selector === "video" ? [second] : [{ href: "/reel/DistinctB2/" }]; } };
  assert.equal(api.targetFor(first, currentURL, 2), "https://www.instagram.com/reel/DistinctA1/");
  assert.equal(api.targetFor(second, currentURL, 2), "https://www.instagram.com/reel/DistinctB2/");
});
test("a generic single visible player can use its page, while social feed roots stay unmapped", () => {
  const visible = { left: 100, right: 740, top: 100, bottom: 460, width: 640, height: 360 };
  const hidden = { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
  const [current] = feedPlayers([hidden, visible]).slice(1);
  assert.equal(api.targetFor(current, "https://public-site.com/watch/one", 3), "https://public-site.com/watch/one");
  assert.equal(api.targetFor(current, "https://www.instagram.com/reels/", 3), null);
  assert.equal(api.targetFor(current, "https://x.com/home", 3), null);
});
test("supported social post URLs resolve only for the focused player and broad containers do not supply a guessed link", () => {
  const rect = { left: 100, right: 740, top: 100, bottom: 460, width: 640, height: 360 };
  const [current] = feedPlayers([rect]);
  for (const url of ["https://x.com/example/status/1234567890", "https://www.facebook.com/reel/1234567890/", "https://www.tiktok.com/@example/video/1234567890"]) assert.equal(api.targetFor(current, url, 5), url);
  const [first, second] = feedPlayers([rect, { ...rect, left: 800, right: 1140 }]);
  const broad = { parentElement: null, querySelectorAll(selector) { return selector === "video" ? [first, second] : [{ href: "https://www.instagram.com/reel/Unrelated1/" }]; } };
  first.parentElement = broad;
  assert.equal(api.targetFor(first, "https://www.instagram.com/", 2), null);
});
test("a newly focused reel cannot inherit the previous permalink before SPA navigation updates", () => {
  const visible = { left: 300, right: 700, top: 60, bottom: 780, width: 400, height: 720 };
  const outside = { ...visible, top: 900, bottom: 1620 };
  const [first, second] = feedPlayers([visible, outside]);
  const oldURL = "https://www.instagram.com/reels/DeZtDYYNCWf/";
  assert.equal(api.targetFor(first, oldURL, 2), oldURL);
  first.getBoundingClientRect = () => outside; second.getBoundingClientRect = () => visible;
  assert.equal(api.targetFor(second, oldURL, 2), null);
  assert.equal(api.targetFor(second, oldURL + "?tracking=changed", 2), null);
  const nextURL = "https://www.instagram.com/reels/NextReel123/";
  assert.equal(api.targetFor(second, nextURL, 2), nextURL);
});
test("a recycled opaque player needs an updated permalink or its own matching card link", () => {
  const rect = { left: 300, right: 700, top: 60, bottom: 780, width: 400, height: 720 };
  const [current] = feedPlayers([rect]);
  const oldURL = "https://www.instagram.com/reels/DeZtDYYNCWf/";
  assert.equal(api.targetFor(current, oldURL, 1), oldURL);
  current.currentSrc = "blob:https://www.instagram.com/next-video";
  assert.equal(api.targetFor(current, oldURL, 1), null);
  current.parentElement = { parentElement: null, querySelectorAll(selector) { return selector === "video" ? [current] : [{ href: "/reel/NextReel123/" }]; } };
  assert.equal(api.targetFor(current, oldURL, 1), "https://www.instagram.com/reel/NextReel123/");
  assert.equal(api.targetFor(current, "https://www.instagram.com/reels/NextReel123/", 1), "https://www.instagram.com/reel/NextReel123/");
});
test("LinkedIn feed players prefer their exposed signed sources and never send the unsupported feed URL", () => {
  const pageURL = "https://www.linkedin.com/feed/", mp4 = "https://dms.licdn.com/video.mp4?token=a%2Fb&expires=123", manifest = "https://dms.licdn.com/master.m3u8?token=c%2Fd";
  const current = video({ getAttribute(name) { return name === "data-sources" ? JSON.stringify([{ src: mp4, type: "video/mp4", "data-bitrate": 2000000 }, { src: manifest, type: "application/vnd.apple.mpegurl" }]) : null; } });
  const sources = api.sourceEvidenceFor(current, pageURL);
  assert.equal(sources.length, 2); assert.equal(sources[0].url, manifest); assert.equal(sources[1].url, mp4);
  assert.equal(api.targetFor(current, pageURL, 1, sources), manifest);
  assert.equal(api.targetFor(video(), pageURL, 1), null);
  const post = "https://www.linkedin.com/feed/update/urn:li:activity:7016901149999955968/";
  assert.equal(api.targetFor(video(), post, 1), post);
  assert.equal(api.providerURL("https://www.linkedin.com/posts/example_video-activity-7151241570371948544-4Gu7"), "https://www.linkedin.com/posts/example_video-activity-7151241570371948544-4Gu7");
});
test("resource timing is attributed only to a matching player asset and known complete media paths", () => {
  const asset = "D4D05AQExampleAsset01", other = "D4D05AQDifferentAsset2";
  const current = video({ poster: `https://media.licdn.com/dms/image/v2/${asset}/videocover-high/0/12345` });
  const progressive = `https://dms.licdn.com/playlist/vid/v2/${asset}/mp4-720p-30fp-crf28/mp4-720p-30fp-crf28/0/1787692043117?token=a%2Fb`;
  const entries = [
    { name: progressive },
    { name: `https://dms.licdn.com/playlist/vid/v2/${other}/mp4-1080p/0/1792500067911` },
    { name: `https://dms.licdn.com/playlist/vid/v2/${asset}/dash-720p/0/1792500067911` },
    { name: `https://dms.licdn.com/playlist/vid/v2/${asset}/hls-720p/0/segment-1.m4s` },
    { name: `https://dms.licdn.com/playlist/vid/v2/${asset}/0/unknown-timestamp` }
  ];
  const sources = api.sourceEvidenceFor(current, "https://www.linkedin.com/feed/", entries);
  assert.equal(sources.length, 1); assert.equal(sources[0].url, progressive); assert.equal(sources[0].mime, "video/mp4");
  assert.equal(api.targetFor(current, "https://www.linkedin.com/feed/", 5, sources), progressive);
  assert.equal(api.sourceEvidenceFor(video(), "https://www.linkedin.com/feed/", entries).length, 0, "one visible player does not own all network traffic");
});
test("a shared feed container cannot lend another player's source configuration to the clicked player", () => {
  const first = video(), second = video(), pageURL = "https://www.linkedin.com/feed/";
  first.parentElement = { querySelectorAll() { return [first, second]; }, getAttribute() { return JSON.stringify([{ src: "https://dms.licdn.com/unrelated.mp4", type: "video/mp4" }]); } };
  assert.equal(api.sourceEvidenceFor(first, pageURL).length, 0);
  first.getAttribute = name => name === "data-sources" ? "[{invalid json" : null;
  assert.equal(api.sourceEvidenceFor(first, pageURL).length, 0);
  first.mediaKeys = {};
  first.currentSrc = "https://dms.licdn.com/protected.mp4";
  assert.equal(api.sourceEvidenceFor(first, pageURL).length, 0);
});
test("modern LinkedIn CSS poster siblings identify only their nearest single video player", () => {
  const asset = "D5605AQFef3z_ctGk6A", pageURL = "https://www.linkedin.com/feed/";
  const poster = `https://media.licdn.com/dms/image/v2/${asset}/videocover-low/B56aFZVE_OJYBI-/0/1792500062413?e=123&token=a%2Fb`;
  const progressive = `https://dms.licdn.com/playlist/vid/v2/${asset}/mp4-720p-30fp-crf28/0/1792500067911?token=c%2Fd`;
  const current = video({ poster: "" }), sibling = { style: { backgroundImage: `url("${poster}")` } };
  const player = { className: "video-js vjs-paused", hasAttribute(name) { return name === "data-vjs-player"; }, querySelectorAll(selector) { return selector === "video" ? [current] : selector.includes("background-image") ? [sibling] : []; } };
  current.parentElement = player;
  assert.equal(api.posterFor(current, pageURL), poster);
  const sources = api.sourceEvidenceFor(current, pageURL, [{ name: progressive }]);
  assert.equal(sources.length, 1); assert.equal(sources[0].url, progressive);
  assert.equal(api.targetFor(current, pageURL, 1, sources), progressive);
  const other = video();
  player.querySelectorAll = selector => selector === "video" ? [current, other] : [sibling];
  assert.equal(api.posterFor(current, pageURL), null, "a shared feed wrapper does not establish poster ownership");
  assert.equal(api.sourceEvidenceFor(current, pageURL, [{ name: progressive }]).length, 0);
});
test("explicit video posters win over nearby images and layered backgrounds are not guessed", () => {
  const current = video({ poster: "https://cdn.public-site.com/own-poster.jpg?token=a%2Fb" });
  const sibling = { style: { backgroundImage: "url(https://cdn.public-site.com/one.jpg), url(https://cdn.public-site.com/two.jpg)" } };
  current.parentElement = { querySelectorAll(selector) { return selector === "video" ? [current] : [sibling]; } };
  assert.equal(api.posterFor(current, "https://public-site.com/watch"), current.poster);
  current.poster = "";
  assert.equal(api.posterFor(current, "https://public-site.com/watch"), null);
});
