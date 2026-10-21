import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
if (!globalThis.crypto) globalThis.crypto = webcrypto;
let listener;
const event = () => ({ addListener() {} });
globalThis.chrome = {
  runtime: { id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", getURL: path => `chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/${path}`, onMessage: { addListener(callback) { listener = callback; } }, onInstalled: event(), onStartup: event(), connectNative() {
    let onMessage; return { onMessage: { addListener(callback) { onMessage = callback; } }, onDisconnect: event(), postMessage(request) { queueMicrotask(() => onMessage({ protocolVersion: 1, requestID: request.requestID, serviceVersion: "0.4.0", mediaPanelAvailable: true })); }, disconnect() {} };
  } },
  tabs: { onUpdated: event(), onActivated: event(), onRemoved: event() },
  permissions: { async getAll() { return { origins: [] }; }, onAdded: event(), onRemoved: event() },
  storage: { session: { async get() { return {}; } }, local: { async get() { return {}; } } },
  contextMenus: { onClicked: event() }
};
await import("../background.js");
test("missing webRequest and webNavigation APIs cannot prevent desktop bridge startup", async () => {
  assert.equal(chrome.webRequest, undefined);
  const response = await new Promise(resolve => listener({ type: "connection" }, { id: chrome.runtime.id, url: chrome.runtime.getURL("popup.html") }, resolve));
  assert.equal(response.ok, true); assert.equal(response.connected, true); assert.equal(response.mediaPanelAvailable, true);
});
