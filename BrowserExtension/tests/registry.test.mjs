import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { collectCandidates, isNetworkMedia, mergePageCandidates, reviewAcknowledgment, safeThumbnail, usableMediaCount } from "../core.js";
import { applyNetworkObservation, applySnapshot, compactRegistry, freshRegistry, MAX_NETWORK_AGE_MS, registrySnapshot } from "../registry.js";
import { playerTarget } from "../panel-security.js";
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const pageURL = "https://public-site.com/watch";

test("posters, source titles and page fallback metadata remain distinguishable", () => {
  const candidates = collectCandidates([
    { url: "/a.mp4?sig=a%2Fb", kind: "media", assetID: "first", title: "<b>First video</b>\n", titleSource: "Video title", thumbnailURL: "/poster-a.jpg", thumbnailSource: "Video poster" },
    { url: "/b.mp4", kind: "media", assetID: "second" },
    { url: "/image.jpg", kind: "file" },
    { url: "/init.mp4", kind: "resource" },
    { url: "/segment-4.m4s", kind: "media" }
  ], pageURL, { pageTitle: "Page title", pageImage: "/page-poster.jpg" });
  assert.equal(candidates.length, 2);
  assert.equal(candidates[0].title, "<b>First video</b>");
  assert.equal(candidates[0].thumbnailURL, "https://public-site.com/poster-a.jpg");
  assert.equal(candidates[0].thumbnailSource, "Video poster");
  assert.equal(candidates[1].thumbnailSource, "Page image fallback");
  assert.equal(candidates[1].pageTitle, "Page title");
  assert.equal(candidates[0].url, "https://public-site.com/a.mp4?sig=a%2Fb");
  for (const thumbnail of ["data:image/png;base64,abc", "javascript:alert(1)", "http://127.0.0.1/poster.jpg"]) assert.equal(safeThumbnail(thumbnail, pageURL), null);
});
test("only relevant media/manifest response metadata qualifies, not segments, images or HTML", () => {
  assert.equal(isNetworkMedia("https://cdn.public-site.com/no-extension?token=1", "application/dash+xml", "xmlhttprequest"), true);
  assert.equal(isNetworkMedia("https://cdn.public-site.com/film", "video/mp4", "media"), true);
  for (const [url, mime, type] of [["/segment-8.mp4", "video/mp4", "media"], ["/a.m4s", "video/mp4", "media"], ["/a.ts", "video/mp2t", "media"], ["/a.jpg", "image/jpeg", "image"], ["/master.m3u8", "text/html", "xmlhttprequest"], ["/film.mp4", "video/mp4", "script"]]) assert.equal(isNetworkMedia(new URL(url, pageURL).href, mime, type), false);
});
test("one logical DOM player merges observed renditions without stripping signed URL variants", () => {
  const network = collectCandidates([{ url: "https://cdn.public-site.com/master.m3u8?sig=1", kind: "network", requestType: "xmlhttprequest" }, { url: "https://cdn.public-site.com/file.mp4?sig=2", kind: "network", requestType: "media" }], pageURL, { pageTitle: "Fallback" });
  const result = mergePageCandidates([], network, { players: [{ assetID: "one-player", title: "Actual film", titleSource: "Nearby caption", thumbnailURL: "https://public-site.com/poster.jpg", thumbnailSource: "Video poster" }] });
  assert.equal(result.length, 1); assert.equal(result[0].title, "Actual film"); assert.equal(result[0].variants.length, 2); assert.equal(result[0].variants[1].url, network[1].url); assert.equal(usableMediaCount(result), 1);
  const protectedResult = mergePageCandidates([], network, { protectedMedia: 1 }); assert.equal(usableMediaCount(protectedResult), 0); assert.equal(protectedResult[0].usable, false);
});
test("document and SPA URL changes reset old network attribution; expired observations do not count", () => {
  let registry = freshRegistry(12, pageURL, "Old", "old-document");
  registry = applyNetworkObservation(registry, 12, pageURL, { url: "https://cdn.public-site.com/old.mp4", requestType: "media" });
  assert.equal(registrySnapshot(registry).usableMediaCount, 1);
  registry.network[0].observedAt = Date.now() - MAX_NETWORK_AGE_MS - 1;
  assert.equal(registrySnapshot(registry).usableMediaCount, 0);
  registry.network[0].observedAt = Date.now();
  const nextDocument = applySnapshot(registry, 12, { pageURL, title: "Fresh", observations: [] }, "new-document"); assert.equal(nextDocument.network.length, 0);
  const nextSPA = applySnapshot(registry, 12, { pageURL: "https://public-site.com/next", title: "Next", observations: [] }, "old-document"); assert.equal(nextSPA.network.length, 0); assert.notEqual(nextSPA.epoch, registry.epoch);
});
test("review acknowledgments cannot be confused with enqueued job IDs", () => {
  assert.equal(reviewAcknowledgment({ protocolVersion: 1, requestID: "x", opened: true }, "x"), true);
  assert.equal(reviewAcknowledgment({ protocolVersion: 1, requestID: "x", jobID: "any" }, "x"), false);
  assert.equal(reviewAcknowledgment({ protocolVersion: 1, requestID: "x", opened: true, jobID: "any" }, "x"), false);
  assert.equal(reviewAcknowledgment({ protocolVersion: 1, requestID: "x", opened: true, error: "Failed" }, "x"), false);
});
test("storage pressure removes signed posters before any of 80 compact player targets", () => {
  const players = Array.from({ length: 80 }, (_, index) => ({ assetID: `player-${index}`, title: `Film ${index}`, thumbnailURL: `https://cdn.public-site.com/poster.jpg?sig=${"s".repeat(1500)}`, targetURL: `https://www.instagram.com/reel/Video${index}/`, protected: index === 5, ad: index === 6 }));
  for (const budget of [90, 100]) {
    const registry = applySnapshot(null, 7, { pageURL, title: "Many preloaded reels", players, observations: [] }, "live-document");
    assert.ok(JSON.stringify(registry).length > budget * 1024);
    compactRegistry(registry, budget * 1024);
    assert.ok(JSON.stringify(registry).length <= budget * 1024);
    assert.equal(registry.players.length, 80);
    assert.equal(playerTarget(registry, "player-79"), players[79].targetURL);
    assert.equal(registry.players[5].protected, true); assert.equal(registry.players[6].ad, true);
    assert.equal(registry.players[79].thumbnailURL, null);
  }
});
test("exceptionally large sources still retain the explicitly clicked player under the storage cap", () => {
  const players = Array.from({ length: 80 }, (_, index) => ({ assetID: `player-${index}`, targetURL: `https://cdn.public-site.com/${index}.mp4?sig=${"s".repeat(6000)}` }));
  const registry = applySnapshot(null, 7, { pageURL, players, observations: [] }, "live-document");
  compactRegistry(registry, 90 * 1024, "player-79");
  assert.ok(JSON.stringify(registry).length <= 90 * 1024);
  assert.equal(playerTarget(registry, "player-79"), players[79].targetURL);
});
