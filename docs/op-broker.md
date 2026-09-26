# op-broker: 1Password autofill without 1Password in the browser

The official 1Password browser extension talks to the desktop app over
`1Password-BrowserSupport` and, once unlocked, can ask it for any item: a fully
compromised browser (renderer exploit plus sandbox-local code execution in the
browser process, or a malicious extension update) inherits that. op-broker
replaces it with a design in which **the browser never holds a vault session or
any credential it wasn't just given**. Every credential leaves the vault only after
the user approves that one item, for the origin the dialog shows, and the approval
comes from a component the browser can't reach.

Code: `pkgs/op-broker/` (broker, native host, extension, tests).
NixOS: `nixos/modules/apps/op-broker.nix` (`modules.apps.op-broker`, off by default).

```
 browser sandbox (container or VM)            │  1Password's trust domain (app-onepassword / 1Password VM)
                                              │
 page ─ extension ─(native messaging)─ native host ─ /run/sbx/op/sock ═══► broker ── op ── 1Password app
        (MV3, activeTab, fills on a         (pipe, no state)   │  socket = identity    │  (desktop CLI integration,
         user gesture only)                                    │  validates, matches,  │   or a service-account token)
                                                               │  asks sbx-prompt,     │
                                                               │  rate-limits, audits  │
```

## Where the broker runs, and why

**Next to 1Password, as 1Password's uid (or inside 1Password's VM); never in a
browser sandbox and never as the desktop user.**

- `op` only talks to the desktop app when it runs as the app's uid, from the app's
  `$XDG_RUNTIME_DIR` (the app's IPC socket lives there and is owned by that uid),
  with **gid `onepassword-cli`**: the app resets any connection whose peer gid
  isn't that group ([app integration security][sec]). Here the app runs as
  `app-onepassword` in `sandbox-onepassword.service`, so the broker runs as
  `app-onepassword` with `Group=onepassword-cli`. A setgid wrapper isn't needed
  (and wouldn't work under `NoNewPrivileges`); the primary group is enough.
- Putting the broker in the same DAC domain as the vault means the host user
  (`jrt`) can't read its memory, its `op` session, or its config: a compromised
  jrt can ask the broker for items (and faces the same prompts), but can't bypass
  it. A broker running as jrt would add nothing over giving jrt `op` directly.
- The prompt must also be outside the browser's reach: it's `sbx-prompt` (zenity)
  on the security-context Wayland socket the 1Password launcher already holds for
  `app-onepassword`. The browser can't draw over it, answer it or read it.
- With 1Password in its own VM the broker runs *in that guest* for the same
  reasons; the host then only relays bytes (see *1Password in its VM* below).

Alternatives considered: a broker on the host as jrt driving a "vault runner" as
app-onepassword (the runner would need its own gate, since jrt could call it
directly: two brokers); 1Password Connect or a service account on the host
(a bearer token that reads whole vaults without any prompt; kept only as an opt-in
mode, below).

## Threat model

Assume the browser is **fully compromised**: arbitrary code in the renderer, the
browser process and the extension, inside the browser's sandbox. It can send the
broker anything, at any time, claiming any origin.

What it can get:

- **Only items the user approves, one at a time.** Every `fill` needs a dialog
  answer naming the requester (the broker's name for the socket the request came
  in on; nothing the browser says), the item title and username, the vault, the
  fields, and the **origin** the item will be sent for. A compromised browser can
  claim `https://github.com` while showing something else; the dialog shows
  `github.com`, so it only gets the GitHub login if the user clicks Allow for
  GitHub at that moment. Unsolicited dialogs are the tell.
- **Only items saved for the claimed origin.** Items whose saved URLs don't match
  are never candidates, so the dialog can't be used to "pick" an arbitrary item.
- **"Allow until it stops"** answers let that requester fetch that item for that
  origin (and no more fields than approved) again without a dialog until its
  session ends (below). The same compromise could then refetch it; that is the
  trade-off the button makes, and the default "Allow once" doesn't.
- **Metadata oracle, rate-limited:** a `no-match` answer (no dialog) reveals that
  no item is saved for an origin, so a compromised browser can probe which sites
  you have logins for. Every probe costs a token (default burst 5, 10/min,
  120/hour per requester) and is logged; probing the top 1000 sites takes over
  8 hours. Titles and usernames are never returned without approval.
- Nothing else: no listing, no search, no item ids, no vault names, no session,
  no `op` command line. The protocol has two operations (`hello`, `fill`).

What it can't do:

- Reach the vault, the 1Password app, `op` or the broker's memory: different uid
  (DAC) or a different VM, and the only way in is the per-client socket.
- Impersonate another browser: identity is the socket (each client has its own
  directory with a traverse ACL for exactly its uid), checked again with
  `SO_PEERCRED` (uid) and, for VM relays, the peer's cgroup (a system unit the
  user can't move processes into).
- Flood the user: one dialog on screen at a time, one in-flight request per
  requester, a token bucket, and a cooldown (default 5 min) after 3 denials or
  timeouts in a row.
- Get a credential for a page other than the one it was approved for through the
  extension: the extension re-checks the frame's origin right before filling. (A
  compromised browser can of course read whatever it fills: approval is the
  boundary, not the page.)

Out of scope: root on the host; a compromised 1Password app; a compromised jrt
session driving the dialogs with synthetic input (jrt can inject input via
ydotool/uinput; the dialog protects against the *browser*, not against jrt); a
compromised 1Password VM guest.

## Components and protocol

### Extension (MV3, Firefox and Chromium)

Permissions: `activeTab`, `scripting`, `nativeMessaging`, `contextMenus`. No host
permissions, no declared content scripts, no storage.

- Triggers: toolbar button, **Ctrl+Shift+L**, or the context menu ("Fill 1Password
  login"). Each is a user gesture, which is what grants `activeTab` for that tab.
  Nothing runs on page load; pages are never read until the user asks.
- On trigger: inject `content.js` into the tab (all frames it can access, or the
  context-menu frame), which finds a visible login form: a current-password field
  (sign-up forms with only `new-password` fields are ignored), the username field
  before it (`autocomplete=username`/`email` preferred), and a one-time-code field
  (`autocomplete=one-time-code` or an OTP-looking name). Username-only first steps
  and TOTP-only second steps work too.
- Sends `{"op":"fill","origin":<frame origin>,"top":<tab origin if different>,
  "want":[...]}` through one long-lived native port (it also tells the broker the
  browser is still running).
- On success, fills the fields (native value setter plus `input`/`change` events,
  so React-style forms notice) after checking `location.origin` still equals the
  approved origin, then drops the values. It never submits the form.
- A badge shows the result (`ok`/`x`, the reason in the tooltip).

One source manifest; the build derives the Firefox variant (`background.scripts`,
`browser_specific_settings.gecko.id`) and the Chromium one
(`background.service_worker`, `key` pinning the id).

### Native messaging host (in the browser sandbox)

`op-broker-native-host`: 4-byte native-endian length + JSON on stdio (the browser
spawns it), one JSON line per request to `/run/sbx/op/sock` (or
`$OP_BROKER_SOCKET`). Limits: 16 KiB from the extension, 64 KiB from the broker,
1 MiB to the browser. It re-serializes requests and relays replies; it keeps no
state and holds a credential only while copying it from the broker's reply to
stdout. On broker errors it answers `unavailable` and reconnects next time.

### Broker protocol (native host ↔ broker)

One JSON object per line, UTF-8, strictly one reply per request, in order:

| request | reply |
| --- | --- |
| `{"v":1,"op":"hello","id"?:n}` | `{"v":1,"ok":true,"requester":"Firefox"}` |
| `{"v":1,"op":"fill","id"?:n,"origin":"https://a.example","top"?:"https://b.example","want":["username","password","totp"]}` | `{"v":1,"ok":true,"title":…,"username":…,"password":…,"totp":…}` |
| anything else | `{"v":1,"ok":false,"error":"bad-request"}` |

Errors: `bad-request`, `no-match`, `denied`, `busy`, `rate-limited`, `cooldown`,
`unavailable`, `internal`. Unknown keys, a wrong version, non-integer ids,
duplicate or unknown `want` entries, and anything that isn't a canonical origin
are rejected. Lines over 16 KiB drop the connection.

**Origins** must be exactly what `URL.origin` produces: `https://` (or `http://`
only with `match.allowHttp`), lowercase ASCII host (punycode, never raw Unicode,
so homographs show as `xn--…`), valid DNS labels or an IP literal, no default
port, no path/userinfo/trailing dot/whitespace. The broker refuses rather than
normalizes, so the dialog shows exactly what was sent. (`null` origins from
sandboxed iframes and `file:` pages are refused.)

### Broker ↔ op

`op` runs with fixed argument lists (never a shell), validated 26-character ids,
a minimal environment (`HOME`, `XDG_RUNTIME_DIR`, `OP_CONFIG_DIR`, `LANG`, and
the token in service-account mode), a 30 s timeout and a 32 MiB output cap:

- `op item list --categories Login --format json [--vault V] [--account A]`:
  metadata only (`id`, `title`, `vault`, `urls`, `additional_information`, i.e.
  the username). Cached 60 s.
- after approval, for exactly the chosen item:
  `op item get ID --vault VAULT_ID --format json --reveal`, reading the fields
  whose `purpose` is `USERNAME`/`PASSWORD` and the `totp` of the `OTP` field;
- if the JSON carries no current code: `op item get ID --vault VAULT_ID --otp`.

Only the requested fields are returned; notes and other fields are dropped.

### Matching

Items match on their saved URLs, parsed leniently (`github.com` means
`https://github.com`; paths are ignored; IDNs become punycode):

- scheme: an https item never goes to an http page; an http item may go to https;
- port: equal (both default, or the same explicit port);
- host: equal, or with `match.mode = "subdomain"` (default) the page is a subdomain
  of the saved host (saved `github.com` fills on `gist.github.com`; saved
  `login.example.com` never fills on `example.com` or `evil.example.com`;
  `github.com.evil.com` never matches). There's no public-suffix list in the
  stdlib, so single-label hosts and IPs match exactly only. `"exact"` turns
  subdomains off.

Candidates are ordered exact-host first, then by title. One candidate → the
approval dialog. Several → `op-broker-choose` (a zenity list with the requester
and origin; titles shown as plain text), then the approval dialog for the chosen
one. Cancelling the chooser counts as a denial.

### The dialog

`sbx-prompt [--timeout 60] [--no-session] -- REQUESTER SUMMARY DETAIL`:

```
Firefox asks to:
  fill the 1Password login "GitHub (jacob)" on https://github.com

  Fields: username, password, one-time code
  Vault: Personal
  The login form is embedded in a page from https://news.example.   (only if top ≠ origin)
  Saved for: https://github.com
```

REQUESTER is the broker's label for the socket. Titles and usernames come from the
vault and are cleaned (control, format and bidi-override characters replaced,
length-bounded); zenity shows them without markup. Buttons: **Allow once**,
**Allow until it stops**, **Deny**; no answer in 60 s is a denial.

### Sessions ("Allow until it stops")

A grant is keyed by (requester, item, origin) and covers the approved fields. It
lives while the requester has a broker connection open (the extension keeps its
native port open; Chromium keeps the service worker alive while a native port is
open), plus `sessionIdle` (300 s) after its last connection closes (Firefox's
event page can be suspended), and never longer than `sessionMax` (8 h). A broker
restart (which happens with every 1Password restart) drops all grants. With a
grant for exactly one of several candidates, that one is filled without the
chooser.

### Rate limiting

Per requester: token bucket (`burst` 5, `perMinute` 10), `perHour` 120; hits,
misses and session fills all cost a token. One in-flight fill per requester
(`busy`), one dialog on screen overall (a second requester waits up to 5 s, then
`busy`). After `denyLimit` (3) denials or timeouts in a row: `cooldown` for
`denyCooldown` (300 s). All in `modules.apps.op-broker.limits`.

### Audit log

One JSON line per event on stderr (the journal: `journalctl -u op-broker`) and
in `/var/lib/op-broker/audit.jsonl` (0600, app-onepassword): time, requester,
peer pid/uid/cgroup, origin and top origin, requested fields, item id and title,
decision (`once`, `session`, `session-cached`, `deny`, `no-match`,
`rate-limited`, `cooldown`, `busy`, `unavailable`) and delivered field names.
Never a secret; the tests check that.

## Deployments

### 1Password in its container (default), browsers in containers — wired

- `op-broker.service`: `User=app-onepassword`, `Group=onepassword-cli`,
  `WantedBy=`/`BindsTo=sandbox-onepassword.service` (it runs exactly while
  1Password runs), `XDG_RUNTIME_DIR=/run/app-onepassword`, dialogs on
  `/run/user/<uid>/sandbox-onepassword-wayland` bound in with `BindPaths=`
  (jrt's runtime dir has no ACL for app uids, by design), `ProtectSystem=strict`,
  no network (`IPAddressDeny=any`, AF_UNIX only), empty capability set.
- 1Password's own nixpak sandbox additionally binds its runtime dir (so the CLI
  socket the app creates there is on the host, where the broker, same uid, sees
  it) and `/etc/group` (so the app can resolve `onepassword-cli`).
- `/run/op-broker/clients/<app>/` (0710, owner the broker uid, ACL `u:<client>:--x`)
  holds each client's socket. The browser's sandbox binds that directory at
  `/run/sbx/op` (a directory, so a restarted broker's new socket is seen) and the
  native host manifest where it looks, via `modules.apps.<browser>.sandbox.nixpakModules`.

### Browser in a VM — needs a core hook

The browser VM's native host connects to `/run/sbx/op/sock` in the guest; the VM's
vsock relay carries it to the host as service `op`, and the per-VM host relay
(`sandbox-vm-<app>-relay.service`, as jrt) connects it to
`/run/op-broker/clients/<app>/sock`. The broker accepts it because the peer is
jrt **and** its cgroup is `/system.slice/sandbox-vm-<app>-relay(@…).service`.
Nothing else changes: requester identity is still "which socket".

### 1Password in its VM — needs core hooks

The host can't reach into a guest (the relay is guest→host only), so the broker
inside the 1Password guest **dials out**:

```
browser (container or VM) ─► /run/op-broker/clients/<app>/sock ─► op-broker-bridge (host, own uid)
                                                                     │ pairs each client connection with an idle uplink,
                                                                     │ sends {"v":1,"client":"<app>"}\n first, then splices
1Password VM: op-broker uplink ─► /run/sbx/op-uplink/sock ─vsock "op-uplink"─► /run/op-broker/uplink/sock
```

- `op-broker uplink` keeps a pool of idle connections to the bridge (default 4,
  replacing each as soon as it's paired, up to 64), reads the header naming the
  client (must be a configured client), then serves that connection exactly like
  `serve` does, including prompts and grants, inside the guest.
- `op-broker-bridge.service` (host, `op-broker-bridge` uid, AF_UNIX only) owns the
  client sockets, checks peers like the broker does, and accepts uplinks only
  from jrt in `sandbox-vm-onepassword-relay.service`. It holds no secrets; a
  compromised bridge could mislabel requesters, not skip prompts.
- Browser in one VM and 1Password in another: both hooks at once; the host path
  is relay → client socket → bridge → uplink relay → broker.

The in-guest broker needs gid `onepassword-cli` in the guest (the app checks it
there), and runs with the guest's config file from
`modules.apps.op-broker.guestBroker`.

### Service-account mode (opt-in)

`auth = "service-account"`: `op` uses `OP_SERVICE_ACCOUNT_TOKEN`, no desktop app.
The broker runs as its own `op-broker` uid (network allowed) with the token from
`serviceAccountTokenFile` via `LoadCredential=`. Caveats: service accounts can't
see Personal/Private/Employee vaults (web logins would have to live in a shared
vault granted to the account), have request rate limits, and the token reads
those vaults without any 1Password-side prompt: op-broker's dialog is then the
only gate. Its dialogs need a display: set `prompt.waylandSocket` to a socket the
`op-broker` uid may connect to (otherwise the module warns and every request is
denied).

## Installing the extension

The module exposes everything read-only in `config.modules.apps.op-broker.extension`:

| | |
| --- | --- |
| Firefox/Zen id | `op-broker@otisroot.com` |
| Chromium id | `ilegcnjonhgamikmijhnmbkeaackcfdl` (pinned by the manifest `key`) |
| native host | `com.otisroot.op_broker` |
| XPI | `extension.xpi` / `extension.xpiUrl` (`file:///nix/store/…/op-broker.xpi`, unsigned) |
| unpacked | `extension.firefoxDir`, `extension.chromiumDir` |
| host manifests | `extension.nativeHost` → `lib/mozilla/native-messaging-hosts/`, `etc/chromium/…`, `etc/opt/chrome/…` |

**Zen** (built without `MOZ_REQUIRE_SIGNING`; the pref is honoured): policies
`ExtensionSettings."op-broker@otisroot.com" = { installation_mode = "force_installed"; install_url = xpiUrl; }`
plus the pref `xpinstall.signatures.required = false` (locked). `pkgs.zen-browser`
is a wrapFirefox output, so `extraPolicies`/`extraPrefs` work.

**Firefox (release)** refuses unsigned extensions with no override. Options, in
order of preference: (1) sign it once as an *unlisted* add-on on AMO
(`web-ext sign --channel=unlisted`, needs a Mozilla account; no review listing,
automatic signing) and force-install the signed XPI by path/hash; (2) use
`firefox-esr` or `firefox-devedition` with `xpinstall.signatures.required = false`;
(3) an unbranded build. Same `ExtensionSettings` policy either way. The id must
stay `op-broker@otisroot.com` (the native host manifest allows only it).

**Chromium, ungoogled-chromium, Brave**: add
`--load-extension=${extension.chromiumDir}` to the browser's wrapper flags. It
still works in Chromium-based browsers (only Google-branded Chrome removed it, in
137/142), the id stays `ilegcnjonhgamikmijhnmbkeaackcfdl` because of the `key`,
and nothing has to be packed or signed. `ExtensionInstallForcelist` needs an
update URL serving a signed CRX; if that's ever wanted, generate a new key (the
id changes; update `ids` in `pkgs/op-broker/default.nix`), pack a CRX3 and serve
an update manifest; `--load-extension` avoids all of it.

**Native host manifests** (the module does this for container browsers): Firefox
family reads `~/.mozilla/native-messaging-hosts/<name>.json` (bound in from the
store); wrapFirefox's `nativeMessagingHosts = [ extension.nativeHost ]` also works
(it uses `MOZ_SYSTEM_DIR` when the build has nixpkgs' patch, else links into
`~/.mozilla`). Chromium family reads `/etc/chromium/native-messaging-hosts/`
(Chromium) or `/etc/opt/chrome/native-messaging-hosts/` (Chrome lineage); both are
bound in from the store (the sandboxes have a tmpfs `/etc`). Browsers find hosts
only by manifest location; the manifest's absolute `path` is a store path, and
the store is visible in every sandbox and VM guest.

The official 1Password extension should then be removed/blocked
(`ExtensionSettings."{d634138d-c276-4fc8-924b-40a0ea21d284}".installation_mode =
"blocked"` for Firefox, `ExtensionInstallBlocklist` with
`aeblfdkhhhdcdjpifhhbdiojplfjncoa` for Chromium), and the old
`lib/features/onepassword*.nix` binds (`1Password-BrowserSupport`) dropped from the
browsers.

## Sandbox-core hooks (not done here)

`lib/apps.nix`, `lib/backends/*`, `lib/vm/*` and `nixos/modules/system/sandbox*.nix`
are untouched. What op-broker needs from them:

1. **Relay service `op` for browser VMs** (`lib/backends/vm.nix`): for each app in
   `config.modules.apps.op-broker.relayServices.<app>`, add the service to
   `relayServices`, map it on the host (`op=/run/op-broker/clients/<app>/sock` in
   `relayScript`) and in the guest (`guestSockets.op = "/run/sbx/op/sock"`). The
   host relay already runs as jrt in `sandbox-vm-<app>-relay.service`, which is
   exactly what the broker's peer check expects.
2. **Relay service `op-uplink` for the 1Password VM**: same mechanism,
   `op-uplink=/run/op-broker/uplink/sock` on the host, `/run/sbx/op-uplink/sock` in
   the guest.
3. **Run the uplink broker in the 1Password guest** next to the app, as the guest
   user with gid `onepassword-cli` (and that group in the guest's `/etc/group`), with
   the guest's Wayland display for its dialogs: `modules.apps.op-broker.guestBroker.command`.
   E.g. an app-spec "companion command" the guest launcher starts with the app.
4. **Native-messaging manifest in browser VM guests**: the guest's `/etc` is the
   generic guest's, so either bind `extension.nativeHost/etc/chromium/…` /
   `…/lib/mozilla/…` like the container binds, or have the browser package carry
   it (wrapFirefox `nativeMessagingHosts`).
5. Optional: **end sessions on sandbox stop**: an `ExecStopPost=` on
   `sandbox-<browser>` / `sandbox-vm-<browser>` telling the broker to drop that
   requester's grants now instead of after `sessionIdle`. (Needs a small control
   socket in the broker; not implemented.)

## Verification status

Tested (`python3 -m unittest discover -s pkgs/op-broker/tests`, also run in the
package's `checkPhase`; 37 tests): origin and item-URL validation and matching,
request validation, exact `op` command lines (fake `op` rejects anything else),
dialogs never containing a secret, audit never containing a secret, deny and
cooldown, session grants (scope, idle expiry, max age, `--no-session`), chooser
(ordering, bidi cleaning, cancel, out of range), TOTP (JSON and `--otp`), rate
limits, busy, vault restriction, `--account`, `op` failures, minimal `op`
environment, peer-uid and cgroup refusal, the socket server, the native host
(framing, limits, broker down), and bridge + uplink (pool replacement, header
validation). NixOS: excelsior evaluates with the module disabled, and enabled in
container, VM and service-account variants. The JavaScript is syntax-checked by
node at build time.

**Not verified on hardware** (needs a running session):

- that the 1Password app's CLI socket appears in `/run/app-onepassword` once the
  sandbox binds its runtime dir (`ls -la /run/app-onepassword` as root after
  starting 1Password with the module enabled), and that nixpak doesn't put a tmpfs
  over it;
- that `op` connects from the broker service (`journalctl -u op-broker`, a fill
  attempt → `unavailable` with op's error in the log if not);
- the desktop app's authorization of a tty-less CLI: on Linux the app keys CLI
  sessions on the tty and its start time, and authorizes through polkit action
  `com.1password.1Password.authorizeCLI` (see open questions);
- zenity dialogs from the service on the bound security-context socket;
- Firefox MV3 `activeTab` + `scripting.executeScript` with `allFrames` in Zen,
  and Chromium's native port keeping the service worker alive.

## Open questions

1. **CLI integration needs system authentication.** On Linux "Integrate with
   1Password CLI" requires "Unlock using system authentication" (polkit), and each
   CLI session is authorized through polkit action
   `com.1password.1Password.authorizeCLI` (`auth_self`). The current 1Password
   setup deliberately dropped polkit/system unlock (`auth.nix`), and a service
   running as `app-onepassword` has no polkit agent. Options: install the app's
   polkit policy with `app-onepassword` as owner plus a rule that returns YES for
   `authorizeCLI` when `subject.user == "app-onepassword"` (op-broker's dialog then
   being the only gate, which is its job anyway), or use service-account mode.
   Which do you want?
2. Should `no-match` be silent (current; leaks "no login for this site" to a
   compromised browser at 120 probes/hour), or show a small notice so probing is
   visible?
3. Firefox release needs a signed XPI: OK to sign it as an unlisted AMO add-on
   (your Mozilla account), or switch the Firefox app to ESR/Developer Edition?
4. Keep "Allow until it stops" (default on), or `prompt.allowSession = false`?
5. Is `subdomain` matching the right default, or `exact`?

## Sources

- 1Password CLI app integration security (IPC over a unix socket owned by the
  user; the app checks the peer's gid is `onepassword-cli`; Linux sessions keyed on
  tty + start time; polkit prompts): [developer.1password.com][sec]
- Getting started with 1Password CLI (Linux: polkit + agent required, system
  authentication unlock, setgid `onepassword-cli`):
  <https://developer.1password.com/docs/cli/get-started/>
- The app binary itself (1password 8.12.34): `op-ipc/src/ipc/unix.rs` places the
  socket under `$XDG_RUNTIME_DIR` and refuses a too-open directory;
  `com.1password.1Password.policy.tpl` defines `unlock`, `authorizeCLI`,
  `authorizeSshAgent`.
- Firefox `ExtensionSettings` policy (`file:///` install URLs, `force_installed`):
  <https://firefox-admin-docs.mozilla.org/reference/policies/extensionsettings/>;
  extension signing and `xpinstall.signatures.required` (ESR/Dev/Nightly only):
  <https://wiki.mozilla.org/Add-ons/Extension_Signing>
- Zen honours `xpinstall.signatures.required=false` (built without
  `MOZ_REQUIRE_SIGNING`): <https://github.com/zen-browser/desktop/discussions/8961>
- `--load-extension` removed only from Google-branded Chrome (137, workaround
  gone in 142): <https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY/m/S0ET5wPjCAAJ>
- nixpkgs `wrapFirefox`: `nativeMessagingHosts`, `MOZ_SYSTEM_DIR`
  (`pkgs/applications/networking/browsers/firefox/wrapper.nix`).

[sec]: https://developer.1password.com/docs/cli/app-integration-security/
