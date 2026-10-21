import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
const source = await readFile(new URL("../overlay-ui.js", import.meta.url), "utf8");
function fixture() {
  const roots = [];
  class Element {
    constructor(tag) { this.tagName = tag; this.children = []; this.attrs = {}; this.listeners = {}; this.style = { values: {}, setProperty(key, value) { this.values[key] = value; } }; }
    setAttribute(key, value) { this.attrs[key] = value; }
    append(...children) { this.children.push(...children); }
    attachShadow({ mode }) { const root = new Element("shadow-root"); roots.push(root); this.mode = mode; this.shadowRoot = mode === "closed" ? null : root; return root; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    remove() { this.removed = true; }
  }
  const document = { createElement: tag => new Element(tag), createElementNS: (_, tag) => new Element(tag), documentElement: new Element("html") };
  const sandbox = { document, innerWidth: 1200, innerHeight: 800 }; vm.createContext(sandbox); vm.runInContext(source, sandbox);
  return { document, roots, api: sandbox.__MVDOverlayUI };
}
test("closed-shadow SVG button requires a real click and stays inside the player top-right", () => {
  const page = fixture(); let clicked = 0;
  const trigger = page.api.trigger(() => { clicked += 1; }, "Selected video");
  const host = page.document.documentElement.children[0], root = page.roots[0], button = root.children[1];
  assert.equal(host.mode, "closed"); assert.equal(host.shadowRoot, null); assert.equal(button.children[0].tagName, "svg"); assert.equal(button.children[1].textContent, "Download this video");
  button.listeners.click({ isTrusted: false, stopPropagation() {} }); assert.equal(clicked, 0);
  button.listeners.click({ isTrusted: true, stopPropagation() {} }); assert.equal(clicked, 1);
  trigger.move({ top: 160, right: 900 }); trigger.setVisible(true);
  assert.equal(host.style.values.top, "168px"); assert.equal(host.style.values.display, "block");
  trigger.remove(); assert.equal(host.removed, true);
});
test("top-right inset is stable even with clear space and stays below sticky headers", () => {
  const { api } = fixture(), size = { width: 190, height: 40 }, viewport = { width: 1200, height: 800 };
  const player = { left: 100, right: 1000, top: 300, bottom: 700 };
  const header = { left: 0, right: 1200, top: 0, bottom: 90 };
  const clear = api.triggerPosition(player, [header], size, viewport);
  assert.equal(clear.placement, "inset"); assert.equal(clear.top, 308);
  const toolbar = { left: 100, right: 1000, top: 250, bottom: 296 };
  const crowded = api.triggerPosition(player, [header, toolbar], size, viewport);
  assert.equal(crowded.placement, "inset"); assert.equal(crowded.top, 308);
  const scrolled = api.triggerPosition({ ...player, top: 20 }, [header], size, viewport);
  assert.equal(scrolled.placement, "inset"); assert.ok(scrolled.top >= header.bottom + 6);
});
