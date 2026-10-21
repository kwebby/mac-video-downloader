import test from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
if (!globalThis.crypto) globalThis.crypto = webcrypto;
let popupListener, port, holdResponse = false, intervalCallback;
const sent = [], cleared = [];
const event = () => ({ listeners: [], addListener(callback) { this.listeners.push(callback); }, emit(...args) { this.listeners.forEach(callback => callback(...args)); } });
globalThis.setInterval = (callback, milliseconds) => { assert.equal(milliseconds, 30000); intervalCallback = callback; return 42; };
globalThis.clearInterval = timer => { cleared.push(timer); };
globalThis.chrome = {
  runtime: {
    id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", getURL: path => `chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/${path}`,
    onMessage: { addListener(callback) { popupListener = callback; } }, onInstalled: event(), onStartup: event(),
    connectNative() {
      port = { onMessage: event(), onDisconnect: event(), disconnect() { this.onDisconnect.emit(); }, postMessage(request) {
        sent.push(request);
        if (!holdResponse) queueMicrotask(() => this.reply(request));
      }, reply(request) { this.onMessage.emit({ protocolVersion: 1, requestID: request.requestID, serviceVersion: "0.4.0", mediaPanelAvailable: true }); } };
      return port;
    }
  },
  tabs: { onUpdated: event(), onActivated: event(), onRemoved: event() },
  permissions: { async getAll() { return { origins: [] }; }, onAdded: event(), onRemoved: event() },
  scripting: { async unregisterContentScripts() {} },
  storage: { session: { async get() { return {}; } }, local: { async get() { return {}; } } },
  contextMenus: { onClicked: event(), removeAll(callback) { callback(); }, create() {} }
};
await import("../background.js");
const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const connection = () => new Promise(resolve => popupListener({ type: "connection" }, { id: chrome.runtime.id, url: chrome.runtime.getURL("popup.html") }, resolve));

test("native heartbeat verifies enabled transport, skips busy requests, and stops on disconnect", async () => {
  chrome.runtime.onStartup.emit(); await flush();
  assert.equal(sent.length, 1); assert.equal(sent[0].command, "hello");
  assert.equal(typeof intervalCallback, "function");
  intervalCallback(); await flush();
  assert.equal(sent.length, 2); assert.equal(sent[1].command, "hello");
  holdResponse = true;
  const pending = connection();
  assert.equal(sent.length, 3);
  intervalCallback(); await flush();
  assert.equal(sent.length, 3, "a heartbeat must never interrupt a pending provider request");
  port.reply(sent.at(-1)); assert.equal((await pending).connected, true);
  port.disconnect();
  assert.ok(cleared.includes(42), "disabling/closing the native connection must stop its heartbeat");
});
