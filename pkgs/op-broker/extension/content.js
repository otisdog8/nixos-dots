// Injected on demand (never declared as a content script): only after the user
// triggers a fill, only into the tab they triggered it in (activeTab). Runs in
// the extension's isolated world, so the page can't see or patch these helpers.
(() => {
  if (globalThis.__opBroker) return;

  const TOTP_RE =
    /(one.?time|otp|totp|2fa|mfa|two.?factor|verification.?code|security.?code|auth(entication)?.?code|passcode)/i;
  const USER_RE = /(user|login|email|e-mail|account|identifier)/i;
  const TEXTY = new Set(["text", "email", "tel", "number", ""]);

  function visible(el) {
    if (el.disabled || el.readOnly) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
  }

  function allInputs(root, out, depth) {
    for (const el of root.querySelectorAll("input")) out.push(el);
    if (depth < 3) {
      for (const host of root.querySelectorAll("*")) {
        if (host.shadowRoot) allInputs(host.shadowRoot, out, depth + 1);
      }
    }
    return out;
  }

  const ac = (el) => (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
  const describe = (el) =>
    [el.name, el.id, el.getAttribute("placeholder"), el.getAttribute("aria-label")].join(" ");
  const okOtpLength = (el) => el.maxLength < 0 || (el.maxLength >= 4 && el.maxLength <= 10);
  const kind = (el) => (el.getAttribute("type") || "").toLowerCase();

  function find() {
    const inputs = allInputs(document, [], 0).filter(visible);
    const passwords = inputs.filter((el) => kind(el) === "password");
    // A form with only new-password fields is a sign-up or change form: not ours.
    const password =
      passwords.find((el) => ac(el).includes("current-password")) ||
      passwords.find((el) => !ac(el).includes("new-password")) ||
      null;
    const totp =
      inputs.find((el) => ac(el).includes("one-time-code")) ||
      inputs.find(
        (el) => TEXTY.has(kind(el)) && TOTP_RE.test(describe(el)) && okOtpLength(el),
      ) ||
      null;
    const texty = inputs.filter((el) => TEXTY.has(kind(el)) && el !== totp);
    let username = null;
    if (password) {
      const scope = password.form ? texty.filter((el) => el.form === password.form) : texty;
      const before = scope.filter(
        (el) => el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING,
      );
      username =
        before.find((el) => ac(el).includes("username")) ||
        before.find((el) => kind(el) === "email") ||
        before[before.length - 1] ||
        null;
    } else if (!totp) {
      // First step of a two-step login: the username alone.
      username =
        texty.find((el) => ac(el).includes("username")) ||
        texty.find((el) => ac(el).includes("email")) ||
        texty.find((el) => kind(el) === "email") ||
        texty.find((el) => USER_RE.test(describe(el))) ||
        null;
    }
    return { username, password, totp };
  }

  function setValue(el, value) {
    // The prototype's setter, so frameworks that track the value (React) see
    // the change; then the events a typing user would cause.
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    el.focus();
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function detect() {
    const f = find();
    return {
      origin: location.origin,
      username: !!f.username,
      password: !!f.password,
      totp: !!f.totp,
    };
  }

  function fill(creds, expectedOrigin) {
    // The page may have navigated while the user was answering the dialog.
    if (location.origin !== expectedOrigin) return { ok: false, error: "origin-changed" };
    const f = find();
    let n = 0;
    for (const key of ["username", "password", "totp"]) {
      if (f[key] && typeof creds[key] === "string") {
        setValue(f[key], creds[key]);
        n++;
      }
    }
    return { ok: n > 0, filled: n };
  }

  Object.defineProperty(globalThis, "__opBroker", {
    value: Object.freeze({ detect, fill }),
  });
})();
