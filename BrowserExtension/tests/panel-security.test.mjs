import test from "node:test";
import assert from "node:assert/strict";
import { safeMediaPreview, safeFolders, validateSelection, playerMediaBinding, unsupportedMediaPage } from "../panel-security.js";
const preview = safeMediaPreview({ title: "Movie", formats: [{ id: "v720", label: "720p", hasVideo: true, hasAudio: false, height: 720 }, { id: "a", label: "Audio", hasVideo: false, hasAudio: true }], qualities: [{ id: "best", label: "Best" }, { id: "1080p", label: "1080p", height: 1080 }] });
const folderID = "b9c7c640-6da9-4878-af39-03140f367dc7";
const session = { mediaPreview: preview, folders: safeFolders([{ id: folderID, name: "Films", path: "/secret/path" }]) };
test("folder and preview sanitization exposes labels and IDs without filesystem paths", () => {
  assert.equal(session.folders[0].path, undefined); assert.equal(JSON.stringify(session).includes("/secret/path"), false);
});
test("audio and exact source formats omit conflicting video quality", () => {
  const audio = validateSelection(session, { options: { mode: "audioOnly", formatID: "a", container: "auto", audioFormat: "mp3", audioBitrateKbps: 192 }, quality: { id: "1080p" }, folderID });
  assert.equal(audio.quality, undefined); assert.equal(audio.options.audioBitrateKbps, 192);
  const exact = validateSelection(session, { options: { mode: "videoWithAudio", formatID: "v720" }, quality: { id: "1080p" } }); assert.equal(exact.quality, undefined);
});
test("unresolved source IDs, unapproved folder IDs and lossless/original fixed bitrates are rejected", () => {
  for (const value of [{ options: { mode: "audioOnly", formatID: "unreturned" } }, { options: { mode: "videoOnly" }, folderID: "other" }, ...["original", "wav", "flac"].map(audioFormat => ({ options: { mode: "audioOnly", audioFormat, audioBitrateKbps: 192 } }))]) assert.throws(() => validateSelection(session, value));
});
test("media fallback sources require exact selected-player attribution and actual media resources", () => {
  const pageURL = "https://www.linkedin.com/feed/update/urn:li:activity:1234567890123456789/";
  const signedSource = "https://cdn.public-site.com/master.m3u8?sig=a%2Fb&token=exact";
  const registry = { pageURL, players: [{ assetID: "selected", targetURL: pageURL }, { assetID: "other", targetURL: "https://public-site.com/another-video" }], dom: [
    { assetID: "other", isMedia: true, url: "https://cdn.public-site.com/unrelated.mp4" },
    { assetID: null, isMedia: true, url: "https://cdn.public-site.com/unattributed.mp4" },
    { assetID: "selected", isMedia: true, url: pageURL, variants: [{ url: signedSource }, { url: "https://cdn.public-site.com/segment-1.m4s" }, { url: "https://cdn.public-site.com/poster.jpg" }, { url: "https://cdn.public-site.com/unknown?mime=video/mp4" }, { url: "http://127.0.0.1/private.mp4" }] },
    { assetID: "selected", isMedia: true, protected: true, url: "https://cdn.public-site.com/protected.mp4" }
  ] };
  assert.deepEqual(playerMediaBinding(registry, "selected"), { primaryTarget: pageURL, sourceTargets: [signedSource] });
  registry.players[0].targetURL = null;
  assert.equal(playerMediaBinding(registry, "selected").sourceTargets[0], signedSource);
  registry.players[0].protected = true;
  assert.throws(() => playerMediaBinding(registry, "selected"), /protected playback/);
});
test("source fallback is limited to unsupported extraction, never authentication or protected errors", () => {
  assert.equal(unsupportedMediaPage("Could not resolve this video. ERROR: Unsupported URL: [redacted]"), true);
  assert.equal(unsupportedMediaPage("No video formats found"), true);
  for (const error of ["Sign in required", "HTTP Error 403", "DRM protected", "Unsupported URL: cookies required", "The desktop connection closed", "No video formats found. Authentication required"]) assert.equal(unsupportedMediaPage(error), false);
});

test("extensionless fallback requires attributed media MIME and still excludes fragments and unsafe URLs", () => {
  const pageURL = "https://www.linkedin.com/feed/update/urn:li:activity:1234567890123456789/";
  const source = "https://cdn.public-site.com/playback?id=7&signature=a%2Fb";
  const registry = { pageURL, players: [{ assetID: "selected", targetURL: pageURL }], dom: [
    { assetID: "selected", isMedia: true, url: pageURL, variants: [
      { url: source, mime: "video/mp4" },
      { url: "https://cdn.public-site.com/audio?id=7", mime: "audio/mp4" },
      { url: "https://cdn.public-site.com/unknown?id=7" },
      { url: "https://cdn.public-site.com/page?id=7", mime: "text/html" },
      { url: "https://cdn.public-site.com/segment-1.m4s", mime: "video/mp4" },
      { url: "https://cdn.public-site.com/opaque-segment?id=7", mime: "video/iso.segment" },
      { url: "http://127.0.0.1/private", mime: "video/mp4" }
    ] },
    { assetID: "other", isMedia: true, url: "https://cdn.public-site.com/other", variants: [{ url: "https://cdn.public-site.com/other", mime: "video/mp4" }] }
  ] };
  assert.deepEqual(playerMediaBinding(registry, "selected"), { primaryTarget: pageURL, sourceTargets: [source, "https://cdn.public-site.com/audio?id=7"] });
});
