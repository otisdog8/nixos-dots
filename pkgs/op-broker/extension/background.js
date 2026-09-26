// op-broker autofill: background (Chromium service worker / Firefox event page).
//
// Nothing happens until the user asks: toolbar button, keyboard shortcut or
// context menu. Only then does activeTab let us look at the page, find the login
// fields, and ask the broker (through the native host) for a login for the
// page's origin. The broker asks the user which item and whether to allow it;
// the reply goes straight into the page's fields and is dropped. No storage
// permission, no persistent content scripts, no host permissions.

const api = globalThis.browser ?? globalThis.chrome;
const HOST = "com.otisroot.op_broker";
const REPLY_TIMEOUT_MS = 300000;
const MAX_VALUE = 4096;

// ── Native port ──────────────────────────────────────────────────────────────
// One long-lived port: it also tells the broker this browser is still running,
// which is what bounds "allow until it stops" answers.
let port = null;
let nextId = 1;
const pending = new Map();

function getPort() {
  if (port) return port;
  const p = api.runtime.connectNative(HOST);
  p.onMessage.addListener((msg) => {
    if (!msg || typeof msg !== "object" || typeof msg.id !== "number") return;
    const entry = pending.get(msg.id);
    if (!entry) return;
    pending.delete(msg.id);
    clearTimeout(entry.timer);
    entry.resolve(msg);
  });
  p.onDisconnect.addListener(() => {
    if (port === p) port = null;
    for (const [id, entry] of pending) {
      clearTimeout(entry.timer);
      entry.resolve({ ok: false, error: "unavailable", id });
    }
    pending.clear();
  });
  port = p;
  return p;
}

function request(msg) {
  return new Promise((resolve) => {
    const id = nextId++;
    const timer = setTimeout(() => {
      if (pending.delete(id)) resolve({ ok: false, error: "timeout", id });
    }, REPLY_TIMEOUT_MS);
    pending.set(id, { resolve, timer });
    try {
      getPort().postMessage({ ...msg, v: 1, id });
    } catch (e) {
      pending.delete(id);
      clearTimeout(timer);
      resolve({ ok: false, error: "unavailable", id });
    }
  });
}

// ── Feedback ─────────────────────────────────────────────────────────────────
const MESSAGES = {
  "no-form": "No login form found on this page",
  "no-match": "No 1Password login is saved for this site",
  denied: "Denied",
  busy: "Another request is waiting for an answer",
  "rate-limited": "Too many requests; try again shortly",
  cooldown: "Paused after repeated denials; try again later",
  unavailable: "The 1Password broker is not reachable (is 1Password running?)",
  "bad-request": "The broker refused the request",
  "origin-changed": "The page changed before the login could be filled",
  "unsupported-page": "Only http(s) pages can be filled",
  timeout: "No answer from the broker",
  internal: "Broker error",
};

async function feedback(tabId, ok, code) {
  try {
    await api.action.setBadgeText({ tabId, text: ok ? "ok" : "x" });
    await api.action.setBadgeBackgroundColor({ tabId, color: ok ? "#2e7d32" : "#c62828" });
    await api.action.setTitle({
      tabId,
      title: ok ? "Filled" : `op-broker: ${MESSAGES[code] || code}`,
    });
    setTimeout(() => {
      api.action.setBadgeText({ tabId, text: "" }).catch(() => {});
      api.action.setTitle({ tabId, title: "Fill 1Password login (op-broker)" }).catch(() => {});
    }, 4000);
  } catch (e) {
    // The tab may be gone.
  }
}

// ── Fill ─────────────────────────────────────────────────────────────────────
const busyTabs = new Set();

function frameTarget(tabId, frameId) {
  return frameId === undefined ? { tabId, allFrames: true } : { tabId, frameIds: [frameId] };
}

function pickFrame(results) {
  const score = (r) => (r.password ? 3 : r.totp ? 2 : r.username ? 1 : 0);
  let best = null;
  for (const r of results || []) {
    const d = r && r.result;
    if (!d || typeof d.origin !== "string" || score(d) === 0) continue;
    if (
      !best ||
      score(d) > score(best.result) ||
      (score(d) === score(best.result) && r.frameId === 0)
    ) {
      best = r;
    }
  }
  return best;
}

function str(v) {
  return typeof v === "string" && v.length <= MAX_VALUE ? v : undefined;
}

async function fillTab(tab, frameId) {
  if (!tab || tab.id === undefined || busyTabs.has(tab.id)) return;
  const tabId = tab.id;
  busyTabs.add(tabId);
  try {
    let top;
    try {
      top = new URL(tab.url);
    } catch (e) {
      return feedback(tabId, false, "unsupported-page");
    }
    if (top.protocol !== "https:" && top.protocol !== "http:") {
      return feedback(tabId, false, "unsupported-page");
    }
    const target = frameTarget(tabId, frameId);
    await api.scripting.executeScript({ target, files: ["content.js"] });
    const results = await api.scripting.executeScript({
      target,
      func: () => globalThis.__opBroker.detect(),
    });
    const best = pickFrame(results);
    if (!best) return feedback(tabId, false, "no-form");
    const found = best.result;
    // The top frame must be the page the tab says it shows.
    if (best.frameId === 0 && found.origin !== top.origin) {
      return feedback(tabId, false, "origin-changed");
    }
    const want = [];
    if (found.username || found.password) want.push("username");
    if (found.password) want.push("password");
    if (found.totp) want.push("totp");
    const msg = { op: "fill", origin: found.origin, want };
    if (found.origin !== top.origin) msg.top = top.origin;

    let reply = await request(msg);
    if (!reply || reply.ok !== true) {
      return feedback(tabId, false, (reply && reply.error) || "internal");
    }
    const creds = { username: str(reply.username), password: str(reply.password), totp: str(reply.totp) };
    reply = null;
    const [done] = await api.scripting.executeScript({
      target: { tabId, frameIds: [best.frameId] },
      func: (c, origin) => globalThis.__opBroker.fill(c, origin),
      args: [creds, found.origin],
    });
    creds.username = creds.password = creds.totp = undefined;
    const res = done && done.result;
    feedback(tabId, !!(res && res.ok), (res && res.error) || "no-form");
  } catch (e) {
    feedback(tabId, false, "internal");
  } finally {
    busyTabs.delete(tabId);
  }
}

// ── Triggers (each is a user gesture, which is what grants activeTab) ────────
api.action.onClicked.addListener((tab) => fillTab(tab));

api.commands.onCommand.addListener(async (command, tab) => {
  if (command !== "fill-login") return;
  if (!tab) [tab] = await api.tabs.query({ active: true, currentWindow: true });
  fillTab(tab);
});

api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== "op-broker-fill") return;
  fillTab(tab, typeof info.frameId === "number" ? info.frameId : undefined);
});

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.create({
    id: "op-broker-fill",
    title: "Fill 1Password login",
    contexts: ["editable", "page"],
  });
});

// Open the port when the browser starts, so the broker sees this browser's
// session begin (and end) even before the first fill.
api.runtime.onStartup.addListener(() => {
  try {
    getPort();
  } catch (e) {
    // Retried on the first fill.
  }
});
