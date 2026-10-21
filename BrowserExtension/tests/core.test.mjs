import test from "node:test";
import assert from "node:assert/strict";
import { collectCandidates, durableAcknowledgment, isNetworkMedia, isSegmentURL, validatePublicURL } from "../core.js";

test("blocks unsafe schemes, credentials and local-network inputs in the private build", () => {
  for (const url of ["javascript:alert(1)", "file:///tmp/video.mp4", "https://user:pass@cdn.public-site.com/video.mp4", "http://localhost/a", "http://192.168.1.1/a", "http://2130706433/a", "http://0x7f000001/a", "http://[::1]/a", "http://router.local/a", "http://169.254.169.254/a", "http://100.64.1.1/a", "http://198.18.0.1/a", "http://203.0.113.1/a"]) {
    assert.throws(() => validatePublicURL(url), { name: "Error" }, url);
  }
});

test("retains exact signed resource URLs and does not confuse lookalike providers", () => {
  const input = "https://cdn.public-site.com/path/stream.m3u8?signature=a%2Fb&expires=123#x";
  assert.equal(validatePublicURL(input), input);
  assert.equal(validatePublicURL("https://youtube.com.public-site.com/file.mp4"), "https://youtube.com.public-site.com/file.mp4");
});

test("deduplicates exact URLs, preserves distinct signed variants and recognizes extensionless media tags", () => {
  const page = "https://public-site.com/watch";
  const candidates = collectCandidates([
    { url: "/clip.mp4?token=a", title: " Clip " },
    { url: "/clip.mp4?token=a", title: "Duplicate" },
    { url: "/clip.mp4?token=b" },
    { url: "https://cdn.public-site.com/opaque?id=7", kind: "media" },
    { url: "blob:https://public-site.com/blob", kind: "media" },
    { url: "https://youtube.com/watch?v=x", kind: "media" },
    { url: "/ordinary-page" },
    { url: "http://127.0.0.1/video.mp4" }
  ], page);
  assert.equal(candidates.length, 4);
  assert.equal(candidates[0].title, "Clip");
  assert.equal(candidates[0].downloadable, true);
  assert.equal(candidates[2].kind, "media");
  assert.equal(candidates[2].downloadable, false);
  assert.deepEqual(collectCandidates([], "https://youtube.com/watch?v=x"), []);
});

test("bounded discovery resists huge untrusted DOM observations", () => {
  const candidates = collectCandidates(Array.from({ length: 500 }, (_, index) => ({ url: `https://cdn.public-site.com/${index}.mp4`, title: "a".repeat(500) })), "https://public-site.com");
  assert.equal(candidates.length, 80);
  assert.equal(candidates[0].title.length, 160);
});

test("extensionless source MIME survives a duplicate player observation without MIME", () => {
  const url = "https://cdn.public-site.com/playback?id=7&signature=a%2Fb";
  const candidates = collectCandidates([
    { url, kind: "media", assetID: "selected-player" },
    { url, kind: "media", assetID: "selected-player", mime: "video/mp4; codecs=avc1" }
  ], "https://public-site.com/watch");
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].variants.length, 1);
  assert.equal(candidates[0].variants[0].url, url);
  assert.equal(candidates[0].variants[0].mime, "video/mp4");
});

test("only a matching durable broker acknowledgment means accepted", () => {
  const requestID = "583b56f5-c235-4d87-8e49-21e610d37527";
  const jobID = "d149a8db-153c-4c22-83e1-d8a4e0570f60";
  assert.equal(durableAcknowledgment({ protocolVersion: 1, requestID, jobID }, requestID), true);
  assert.equal(durableAcknowledgment({ protocolVersion: 1, requestID, jobID, error: "Disk full" }, requestID), false);
  assert.equal(durableAcknowledgment({ protocolVersion: 1, requestID: "another", jobID }, requestID), false);
  assert.equal(durableAcknowledgment({ protocolVersion: 1, requestID }, requestID), false);
});
test("ISO segments and LinkedIn DASH init/chunk paths are not complete video sources", () => {
  const prefix = "https://dms.licdn.com/playlist/vid/v2/D4D05AQExampleAsset01/";
  for (const mime of ["video/iso.segment", "audio/iso.segment", "video/iso.segment; codecs=avc1"]) {
    assert.equal(isNetworkMedia(prefix + "unknown/0/1787692043117", mime, "media"), false);
    assert.deepEqual(collectCandidates([{ url: prefix + "unknown/0/1787692043117", kind: "media", mime }], "https://www.linkedin.com/feed/"), []);
  }
  const fragment = prefix + "dash-720p/0/1787692043117";
  assert.equal(isSegmentURL(fragment), true); assert.equal(isNetworkMedia(fragment, "video/mp4", "media"), false);
  assert.equal(isNetworkMedia(prefix + "hls-720p/master.m3u8", "application/vnd.apple.mpegurl", "xmlhttprequest"), true);
  assert.equal(isNetworkMedia(prefix + "dash-720p/manifest.mpd", "application/dash+xml", "xmlhttprequest"), true);
  assert.equal(isNetworkMedia(prefix + "mp4-720p-30fp-crf28/0/1787692043117", "video/mp4", "media"), true);
});
