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
NixOS: `nixos/modules/apps/op-broker.nix` (`modules.apps.op-broker`), on by default
where 1Password runs in its VM, for every supported browser that is enabled.
1Password's own authorization of the broker (and its system-authentication unlock):
`nixos/modules/apps/onepassword-system-auth.nix`, see *1Password's own prompt and
system authentication* below. **1Password in its container can't serve op-broker**
(nor use system authentication): see *1Password in its container* below.

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
- **Metadata oracle, rate-limited and visible:** a `no-match` answer (no dialog)
  reveals that no item is saved for an origin, so a compromised browser can probe
  which sites you have logins for. Every probe costs a token (default burst 5,
  10/min, 120/hour per requester) and is logged; probing the top 1000 sites takes
  over 8 hours. And it doesn't stay silent: 4 different no-login sites within 2
  minutes, or hitting the rate limit, shows a notice naming the browser and the
  sites (see *Probing notice*). Titles and usernames are never returned without
  approval.
- **Subdomain matches are labelled.** With the default `subdomain` matching, a
  login saved for `github.com` is offered on `gist.github.com`; the chooser and the
  approval dialog then say `SUBDOMAIN MATCH: saved for github.com, not for
  gist.github.com`, so a login offered on a subdomain you don't trust (user
  content, a takeover) is visible as such.
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
stdout. On broker errors it answers `unavailable` and reconnects next time, and
says why on stderr (`op-broker-native-host: /run/sbx/op/sock: [Errno 2] …`):
Firefox shows that in its Browser Console, Chromium in its own stderr (the
sandbox unit's journal). Never the reply's content.

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
  subdomains off. Subdomain matching stays the default (a decision: logins saved
  for `example.com` should work on `accounts.example.com`), but such a match is
  always **labelled**: chooser rows get `[SUBDOMAIN: saved for github.com, page is
  gist.github.com]` (with a line explaining the tag), and the approval dialog's
  summary line carries `SUBDOMAIN MATCH: saved for github.com, not for
  gist.github.com` plus an explanation as the first detail line. The audit log
  records `match: exact|subdomain`.

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

A subdomain match (page `https://gist.github.com`, login saved for `github.com`):

```
Firefox asks to:
  fill the 1Password login "GitHub (jacob)" on https://gist.github.com
    SUBDOMAIN MATCH: saved for github.com, not for gist.github.com

  This login is saved for https://github.com; the page is on gist.github.com, a subdomain of it.
  Fields: username, password
  ...
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

### Probing notice

A `no-match` answer needs no dialog, so on its own a compromised browser could
check which sites have a saved login without the user ever noticing. The broker
watches each requester (`ProbeWatch`): **4 different origins with no saved login
within 2 minutes** (repeats of the same origin don't count), or **hitting the rate
limit**, is treated as probing. A person filling forms does neither: each request
needs a user gesture on a page with a login form, and a no-login site means they
tried the extension where they have no account.

It then shows `op-broker-notice` in the background (the request is answered
meanwhile): "Firefox asked for logins on several sites that have none saved",
the sites (the last 8, canonical origins the broker validated), how many, and that
nothing was filled. It can't be used to spam the screen: **at most one notice per
requester per 10 minutes, and one notice on screen at a time** (another is simply
skipped). Its one choice besides Dismiss is **Block it for an hour** (every request
from that requester answers `cooldown`). Each notice and block is in the audit log
(`probe-notice`, `probe-block`). Thresholds: `modules.apps.op-broker.probe`
(`distinct`, `window`, `interval`, `block`; `notice = false` keeps only the audit
events).

Whether a request followed a user gesture isn't knowable to the broker: the
extension only sends on one, but a compromised browser can send anything.

### Audit log

One JSON line per event on stderr (the journal: `journalctl -u op-broker`) and
in `/var/lib/op-broker/audit.jsonl` (0600, app-onepassword): time, requester,
peer pid/uid/cgroup, origin and top origin, requested fields, item id and title,
decision (`once`, `session`, `session-cached`, `deny`, `no-match`,
`rate-limited`, `cooldown`, `busy`, `unavailable`), `match` (`exact` or
`subdomain`) and delivered field names; `probe-notice` / `probe-block` events.
Never a secret; the tests check that.

## Deployments

### 1Password in its container — wired, but the app refuses the broker

**This deployment can't work, and op-broker is off by default with 1Password in
its container (enabling it anyway warns).** Found by reading the 1Password
8.12.34 binary (`resources/app.asar.unpacked/index.node`, which has symbols):

- For a CLI connection the app runs
  `op_sys_info::process_information::linux::verify_process_and_parent_permissions`:
  it takes the peer's pid (`SO_PEERCRED`), then `add_root_ownership_checks` →
  `is_owned_by_root` on the peer's executable and its parent process's, and on
  their directories: `fstat` uid must be 0 (gid 0, or the `onepassword` group),
  permissions from a short list (0755, 0555, 0644, …), and not on FUSE
  (`statfs` magic `0x65735546`). It also checks the peer's effective gid
  (`InvalidIpcPeerEffectiveGid`).
- Before using polkit at all, `op_system_auth::linux::get_system_connector` checks
  that the system bus socket's directory is owned by root
  (`is_owned_by_root(parent(/run/dbus/system_bus_socket))`), else it logs
  "insecure system D-Bus detected … Ignoring the current PolKit interface".
- Its polkit checks use its **own** pid as the subject
  (`zbus_polkit::Subject::new_for_owner(std::process::id(), …)`).

nixpak runs the app with `--unshare-user-try --unshare-pid`. In that unprivileged
user namespace only app-onepassword's own uid/gid are mapped: every root-owned
file (the store, `/run/dbus`) shows up as uid 65534, and a peer gid other than the
app's own shows up as 65534 too. In the pid namespace the broker's `op` (outside
it) has pid 0 as seen by the app, and the app's own pid means nothing to polkitd
on the host. So the CLI connection is refused and system authentication is
disabled, whatever the broker or polkit do. Making it work would need 1Password's
container without a user namespace and in the host pid namespace (a setuid-root
bubblewrap restricted to app-onepassword, or the root runScript building the
sandbox itself) — a sandbox-core change, not done here (a decision for later).
1Password in its VM has neither namespace (see below), which is where op-broker
and system authentication are wired to work.

What the module still generates for it:

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

### Browser in a VM

The browser VM's native host connects to `/run/sbx/op/sock` in the guest; the VM's
vsock relay carries it to the host as service `op`, and the per-VM host relay
(`sandbox-vm-<app>-relay.service`, as jrt) connects it to
`/run/op-broker/clients/<app>/sock`. The broker accepts it because the peer is
jrt **and** its cgroup is `/system.slice/sandbox-vm-<app>-relay(@…).service`.
Nothing else changes: requester identity is still "which socket".

### 1Password in its VM

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
`modules.apps.op-broker.guestBroker`. Its guest service runs as the guest's root
(`sandbox.vm.guestServices.<n>.root`) only to prepare: it copies `op` and
`timeout` to `/run/sbx/op-bin/` (tmpfs, root:root 0755), creates the group, then
`setpriv`s to the user with primary group `onepassword-cli` and runs the broker,
which runs `op` as `/run/sbx/op-bin/timeout 120 /run/sbx/op-bin/op …` (120 s, not
the host serve mode's 30: the first `op` waits for 1Password's authorization,
i.e. for you to answer the host's polkit dialog, and killing op earlier cancels
that dialog under your fingers and counts towards the 3-strikes pause). The
group is also declared in the guest system (`modules.sandbox.vm.guestModules`),
so it exists before 1Password starts and resolves it. The broker's dialogs get
the host's font configuration (the generic guest has no fonts) and GTK's
software renderer (`GSK_RENDERER=cairo`: no GPU behind the cross-domain
display), since guest services get none of the app's GUI environment. Why: the
app's root-ownership checks above apply to the CLI's binary **and its parent's**,
and the guest's `/nix/store` is virtio-fs, i.e. FUSE, with the host's root-owned
files showing as nobody's (crosvm's jailed fs device maps only its own uid). The
copies are root-owned and on tmpfs; `timeout` forks `op` and waits, so it is op's
parent (the broker's interpreter is a store path). Requires
`modules.apps.onepassword-system-auth` (below), which the app needs to authorize
the CLI session at all.

### 1Password's own prompt and system authentication (VM)

The flow the user asked for: log in to 1Password in its VM; the first time the
broker's `op` connects, **1Password asks** (its CLI authorization, through polkit
action `com.1password.1Password.authorizeCLI`); then every fill asks through
op-broker's dialog. And "unlock using system authentication" (polkit action
`com.1password.1Password.unlock`) where possible. Both are polkit checks the app
makes with **its own process** as the subject and user interaction allowed; on
Linux, CLI integration requires system authentication to be on. In the guest
nothing could answer them: the guest user has no password, the app runs over SSH
without a logind session, and there is no polkit. `onepassword-system-auth.nix`
(on by default with 1Password in its VM) adds:

1. **polkit in the guest** (`modules.sandbox.vm.guestModules`, a hook for extra
   modules in the one generic guest system: polkitd is D-Bus activated, so it only
   runs in VMs that use it) and **1Password's policy** from the package's
   `com.1password.1Password.policy.tpl`, with `POLICY_OWNERS=unix-user:<user>`:
   the app only offers system authentication when its user is an owner
   (`is_user_polkit_owner`), and an owner may pass details (authorizeCLI's
   message) with its checks. Defaults stay `auth_self`; with no session polkit
   uses `allow_any`, i.e. `auth_self`, so the identity asked for is the user.
2. **`sbx-polkit-agent`** (`lib/vm/polkit-agent.py`, guest root service): polkit
   agents can be scoped to one unix-process subject, and root may register them
   for any process. It scans `/proc` every 0.5 s and registers itself, **one D-Bus
   connection per registration** (polkitd drops exactly that one when it closes),
   for every process of the user whose executable is `1password` (main process,
   helpers; the Rust core's pid is whichever calls polkit), and drops dead ones.
   `BeginAuthentication` for anything but the two actions, or without the user's
   identity on offer, is refused. For the two actions it sends
   `{"op":"authenticate","action":…}` to the host over the VM's broker socket
   (`/run/sbx/broker.sock`) and waits.
3. **The host asks you, with your own polkit agent.** `sbx-broker` (your session)
   maps the action through `modules.sandbox.broker.sandboxes.vm-onepassword.authenticate`
   to a host action (`org.otisroot.sandbox.onepassword.unlock` /
   `…authorize-cli`, installed with fixed messages, `allow_active = auth_self`,
   nothing for inactive/any, never `_keep`) and runs `pkcheck --process
   <its own pid>,<start>,<uid> --allow-user-interaction`. The broker is a process
   of yours outside a logind session, so polkitd finds your graphical session
   (`sd_uid_get_display`) and its agent (hyprpolkitagent) shows the dialog:
   **real system authentication** (password; fingerprint if PAM's `polkit-1`
   stack has it). One authentication on screen per VM, a 5-minute pause after 3
   failed/dismissed ones in a row (a compromised guest can't keep your password
   dialog up), 5-minute cap; if the guest cancels (polkit's CancelAuthentication)
   the agent closes the connection and the broker kills pkcheck, which cancels
   your dialog.
4. Granted: the guest agent (root) answers polkitd itself
   (`AuthenticationAgentResponse2(0, cookie, unix-user:<user>)`) and returns, and
   1Password's check succeeds. Denied/dismissed: an error, and the app sees a
   failed authorization.

Trust: the host decides, and only for the two actions mapped for exactly this VM;
the guest's root and agent are inside the VM boundary like the app. What the host
gives the guest is one bit ("the user authenticated just now"); no password or
PAM conversation crosses into the guest. Unlike a rule returning YES, nothing is
authorized without the user doing something at that moment.

Assumptions (see the hardware checklist): the subject pid is one of the app's
`1password` processes; the agent registers before the app's first check (0.5 s
scan; a check that comes earlier fails and the app falls back to its password);
1Password accepts a CLI whose parent is `timeout`; the helper scripts' copies
work (`coreutils` is multi-call, dispatched by argv[0]'s basename).

Nested (`sandbox.vm.nested`) is refused by an assertion: the nixpak namespaces
inside the guest would bring back the container's problem.


### Service-account mode (opt-in)

`auth = "service-account"`: `op` uses `OP_SERVICE_ACCOUNT_TOKEN`, no desktop app.
The broker runs as its own `op-broker` uid (network allowed) with the token from
`serviceAccountTokenFile` via `LoadCredential=`. Caveats: service accounts can't
see Personal/Private/Employee vaults (web logins would have to live in a shared
vault granted to the account), have request rate limits, and the token reads
those vaults without any 1Password-side prompt: op-broker's dialog is then the
only gate. Its dialogs get a display of their own: `op-broker-display.service`
(a user service in your graphical session) holds a wp_security_context_v1 socket
at `/run/op-broker/display/wayland-0` (directory `0750 <user>:op-broker`, socket
`0660` through `UMask=0007`), which the broker uses directly: nothing to bind, so
it works whether the session starts before or after the broker.
`prompt.waylandSocket` overrides it.

## Installing the extension

Done automatically by the browser modules (`lib/browser-settings.nix`): every
browser in `modules.apps.op-broker.browsers` gets the extension force-installed
and the official 1Password extension blocked, as described below (Firefox/Zen:
`browser.extensions` + `browser.allowUnsignedExtensions` +
`browser.blockedExtensions`; Chromium family: `browser.unpackedExtensions` +
`browser.blockedExtensions`). The `firefox` app is Firefox Developer Edition
for this reason. The rest of this section is the mechanism.

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
stay `op-broker@otisroot.com` (the native host manifest allows only it). Chosen:
(2), the `firefox` app runs `firefox-devedition` (nixpkgs builds it without
`MOZ_REQUIRE_SIGNING`, so the pref is honoured, as in Zen).

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

The official 1Password extension is blocked
(`ExtensionSettings."{d634138d-c276-4fc8-924b-40a0ea21d284}".installation_mode =
"blocked"` for Firefox, `ExtensionInstallBlocklist` with
`aeblfdkhhhdcdjpifhhbdiojplfjncoa` and the beta `khgocmkkpikpnmmkgmdnfckapcdkgfaf`
for Chromium). Not done yet: dropping the old `lib/features/onepassword*.nix`
binds (`1Password-BrowserSupport`) from the browsers.

## Sandbox-core hooks

Wired through three generic per-app VM options (`lib/apps.nix`,
`lib/vm/instance.nix`, `lib/vm/guest.nix`), which this module sets:

1. `sandbox.vm.relays.op` on browser VMs: host `/run/op-broker/clients/<app>/sock`,
   guest `/run/sbx/op/sock`, carried by the VM's vsock relay (the host end runs
   as jrt in `sandbox-vm-<app>-relay.service`, which the broker's peer check expects).
2. `sandbox.vm.relays.op-uplink` on the 1Password VM: host
   `/run/op-broker/uplink/sock`, guest `/run/sbx/op-uplink/sock`.
3. `sandbox.vm.guestServices.op-broker` on the 1Password VM, with `root = true`
   (new: guest services may run as the guest's root): `guestBroker.command`
   prepares the root-owned `op`/`timeout` copies, creates `onepassword-cli`, and
   drops to the user with that primary group, with the VM's Wayland display and
   session bus. `onepassword-system-auth.nix` adds `guestServices.polkit-agent`
   (root) and a host-wide `modules.sandbox.vm.guestModules` entry (new: extra
   NixOS modules for the one generic guest system) for polkit and the policy.
4. `sandbox.vm.guestBinds` on browser VMs: the native-messaging manifest, bound
   read-only where the browser looks (as the container binds do).
5. Not done: **end sessions on sandbox stop** (an `ExecStopPost=` telling the
   broker to drop that requester's grants; needs a control socket in the broker).

Grouped VMs (modules.sandbox.groups) aren't covered: the peer checks name the
per-app relay unit.

## Verification status

Tested (`python3 -m unittest discover -s pkgs/op-broker/tests`, also run in the
package's `checkPhase`; 45 tests): origin and item-URL validation and matching,
request validation, exact `op` command lines (fake `op` rejects anything else),
dialogs never containing a secret, audit never containing a secret, deny and
cooldown, session grants (scope, idle expiry, max age, `--no-session`), chooser
(ordering, bidi cleaning, cancel, out of range), TOTP (JSON and `--otp`), rate
limits, busy, vault restriction, `--account`, `op` failures, minimal `op`
environment, the `op` launcher, peer-uid and cgroup refusal, the socket server,
the native host (framing, limits, broker down), bridge + uplink (pool
replacement, header validation), the SUBDOMAIN labels (dialog summary and
explanation, chooser rows, audit `match`), and the probing notice (threshold,
repeats not counted, per-requester, one per interval, window expiry, the rate-limit
trigger, the block button → `cooldown`, no notice command → audit only).

`sbx-polkit-agent` (`lib/vm/tests/test_polkit_agent.py`, run when
`lib/vm/polkit-agent.nix` builds; 9 tests) against a private dbus-daemon, a fake
polkitd and a fake host broker: the registration wire format (unix-process
subject with pid/start-time/uid), one connection per registered process, only
matching processes, granted → `AuthenticationAgentResponse2(0, cookie,
unix-user)` then a method return, denied / host unreachable / wrong identity /
unhandled action → an error without a response (and without asking the host for
the last two), CancelAuthentication → `Cancelled` and the host connection
closed, process exit → registration dropped.

NixOS (evaluated): excelsior, galaxy and constitution as configured (1Password in
its container: op-broker and system auth off); excelsior with op-broker forced on
(container: wired, warned); with 1Password and Zen in VMs (op-broker, the bridge,
the guest broker and polkit agent, guest polkit + policy, host auth actions, all
on by default; built); with a service account (own display service). The
JavaScript is syntax-checked by node at build time. Not tested: `sbx-broker`'s
`authenticate` op (pkcheck against a live polkitd), the guest start script.

## Hardware test checklist

Everything below needs the real desktop. 1Password in its VM
(`modules.apps.onepassword.sandbox.mode = "vm"`), a browser with the extension.

1. Guest basics, as root in the 1Password VM (e.g. `sbx-request exec` is
   host-side; use the VM's serial console or `sandbox-vm status onepassword` and
   the guest journal): `systemctl status sbx-svc-polkit-agent sbx-svc-op-broker`
   running; `ls -la /run/sbx/op-bin` shows `op` and `timeout` root:root 0755;
   `pkaction | grep 1password` lists the three actions and
   `pkaction --action-id com.1password.1Password.authorizeCLI --verbose` shows
   `org.freedesktop.policykit.owner: unix-user:jrt`; `ls -ld /run/dbus` root-owned.
2. `stat -f -c %T /nix/store` in the guest says `fuseblk`/`fuse` and `stat -c %U`
   of a store file says `nobody` (confirms why op is copied). If it says root and
   not FUSE, the copies are unnecessary but harmless.
3. Start 1Password; the agent's journal shows `serving … processes` and no
   registration errors; `journalctl -u polkit` in the guest shows "Registered
   Authentication Agent for unix-process:<pid>…" for the 1password processes.
4. In 1Password: Settings → Security → "Unlock using system authentication" is
   offered and can be turned on (if greyed out: its journal/logs say why; look for
   "insecure system D-Bus" or polkit owner messages).
5. Lock 1Password, unlock with system authentication: **hyprpolkitagent on the
   host** asks "1Password, in its sandbox VM, asks you to authenticate to unlock
   it." Correct password → unlocked; Cancel → stays locked, 1Password offers the
   account password. `journalctl --user -u sbx-broker` shows `authenticate
   com.1password.1Password.unlock (as …): authenticated` / `dismissed`.
6. Settings → Developer → "Integrate with 1Password CLI" can be turned on.
7. Trigger a fill (Ctrl+Shift+L on a login page with a saved login): first, the
   host's polkit dialog for the CLI ("The 1Password CLI in 1Password's sandbox
   VM (op-broker …)"), possibly also 1Password's own in-app prompt; then
   op-broker's approval dialog. If the fill answers `unavailable`: the guest's
   `journalctl -u sbx-svc-op-broker` has op's error — look for a rejected peer
   (binary permissions, gid, parent) — that tests the root-owned-copies and
   `timeout`-as-parent assumptions.
8. Cancel the host dialog while 1Password waits: it reports the failure, no
   authorization; three cancels in a row → the next request is refused for 5 min
   without a dialog.
9. Subdomain: a login saved for `example.com`, fill on a subdomain: the dialog's
   second line says `SUBDOMAIN MATCH: saved for …`; with two candidates the
   chooser tags rows `[SUBDOMAIN: …]`.
10. Probing: from the browser, trigger fills on 4 different sites without saved
    logins within 2 minutes: one notice naming the browser and the 4 sites; more
    misses within 10 minutes: no second notice. "Block it for an hour" → fills
    answer "Paused …" for an hour; Dismiss → nothing changes.
11. Allow until it stops: unchanged behaviour (grant survives until the browser's
    port is gone for 5 min).
12. Container (optional, expected to fail): with op-broker forced on and 1Password
    in its container, a fill answers `unavailable` and 1Password's logs show it
    rejected the CLI; "Unlock using system authentication" isn't offered. That
    confirms the analysis above.

## Troubleshooting

For 1Password in its VM (the default). Paste the output of each step; each one
narrows the failure to one hop. `b` is the browser's app name (`firefox`,
`zen-browser`, `ungoogled-chromium`).

**0. The usual suspects.** After a rebuild that touched op-broker, restart the
browser (its sandbox binds `/run/op-broker/clients/<b>` only when it starts) and
1Password (its VM gets the relay, the guest services and the guest system at VM
start). In 1Password: Settings → Security → *Unlock using system
authentication* on, then Settings → Developer → *Integrate with 1Password CLI* on
(the second needs the first; without it every fill answers `unavailable`).
1Password must be running (its VM, and with it the bridge, runs only then).
The extension's toolbar icon shows `x` on failure; its tooltip names the error.

**1. Host: the bridge and the chain behind it, without the browser** (run as
yourself; `sudo` for the app uid):

```sh
b=firefox
systemctl status --no-pager op-broker-bridge sandbox-vm-onepassword sandbox-vm-onepassword-relay
journalctl -b --no-pager -u op-broker-bridge | tail -n 30
sudo ls -la /run/op-broker/clients/$b /run/op-broker/uplink; getfacl -p /run/op-broker/clients/$b

# Talk to the broker exactly as the browser's native host does, as the browser's uid:
nh=$(nix-store -qR /run/current-system | grep -- '-op-broker-native-host-bin-' | head -n 1)/bin/op-broker-native-host
py=$(head -n 1 "$nh" | cut -c3- | cut -d' ' -f1)
opb() { sudo -u app-$b "$py" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode()+b"\n"); print(s.makefile().readline().strip() or "(closed without a reply)")' /run/op-broker/clients/$b/sock "$1"; }
opb '{"v":1,"op":"hello"}'
opb '{"v":1,"op":"fill","origin":"https://github.com","want":["username"]}'   # a site you have a login for
```

| `hello` answers | means | next |
| --- | --- | --- |
| `{"ok": true, "requester": "Firefox", …}` | host, relay, uplink and the broker in the guest all work | the `fill` line; then step 3 if the browser still fails |
| `ConnectionRefusedError` / `FileNotFoundError` | the bridge isn't running (1Password's VM isn't) or never started | `systemctl status op-broker-bridge`, its journal |
| `(closed without a reply)` | the bridge refused the peer | bridge journal: `"refused"` with the uid (and cgroup) it saw |
| `{"ok": false, "error": "unavailable"}` | the bridge has no uplink from the guest: bridge journal says `no uplink (is 1Password running?)` | step 2 (guest broker, relay) |

| `fill` answers | means |
| --- | --- |
| `"ok": true` with your username, after op-broker's dialog | everything works; a browser failure is in step 3 |
| `no-match` | works; no login saved for that origin (item website URLs) |
| `unavailable` (no dialog) | `op` failed in the guest: step 2, the broker's journal has op's error |
| `denied` with no dialog on screen | the dialog couldn't be shown in the guest: step 2, dialog test |
| `cooldown` / `rate-limited` / `busy` | the limits in *Rate limiting* (restart the VM to reset) |

The first `fill` after 1Password starts shows the **host's** polkit dialog
(hyprpolkitagent: "The 1Password CLI in 1Password's sandbox VM … asks you to
authenticate"), maybe 1Password's own prompt, then op-broker's dialog. The host
side of that: `journalctl --user -b -u sbx-broker | grep authenticate`
(`authenticated` / `dismissed` / `no authentication agent` → is
`hyprpolkitagent` running? / `paused after repeated failed authentications` →
wait 5 minutes).

**2. Inside 1Password's VM** (SSH as yourself, as the launcher does; your user
there may read the whole guest journal):

```sh
cid=$(( 3 + 16#$(printf %s onepassword/main | sha256sum | cut -c1-7) ))
rt=/run/sandbox-vm/onepassword/main
vmssh() { ssh -F /dev/null -o "ProxyCommand=/run/current-system/systemd/lib/systemd/systemd-ssh-proxy %h %p" \
  -o ProxyUseFdpass=yes -o User=$USER -o IdentityFile=$rt/client/id_ed25519 -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=$rt/client/known_hosts -o HostKeyAlias=sandbox-vm -o BatchMode=yes -T "vsock/$cid" \
  "PATH=/run/current-system/sw/bin; $1"; }

vmssh 'systemctl status --no-pager sbx-svc-op-broker sbx-svc-polkit-agent sbx-relay'
vmssh 'journalctl -b --no-pager -u sbx-svc-op-broker | tail -n 40'
vmssh 'ls -ld /run/sbx /run/sbx/op-bin; ls -la /run/sbx/op-bin /run/sbx/op-uplink /run/user/$(id -u); getent group onepassword-cli'
vmssh 'ps -eo pid,user,group,args | grep -e op-broker -e 1password | grep -v grep'
vmssh 'journalctl -b --no-pager -u sbx-svc-polkit-agent -u polkit | tail -n 30'
```

- `sbx-svc-op-broker` must be active; its journal starts with `"event": "ready",
  "mode": "uplink"` and shows one `connect … "via": "uplink"` per browser
  connection and one `fill` line per request, with `decision` and, for
  `unavailable`, `reason`: op's own error. `op exited 1: … connecting to
  desktop app …` → CLI integration is off, 1Password isn't running, or it
  rejected the CLI (binary/parent ownership, gid: see *1Password in its VM*);
  `op failed to run: TimeoutExpired` → nobody answered 1Password's
  authorization within 2 minutes; `multiple accounts` → set
  `modules.apps.op-broker.account`.
- `/run/sbx/op-bin/{op,timeout}` root:root 0755; `/run/sbx` root-owned;
  `/run/sbx/op-uplink/sock` exists; `/run/user/<uid>` has
  `1Password-BrowserSupport.sock` (1Password's CLI socket: none means the app
  isn't running in this VM) and `wayland-0`; the group exists; the broker's
  process runs as you with group `onepassword-cli`.
- The polkit agent says `serving …` and `Registered Authentication Agent …`
  appears in polkit's log for the `1password` processes; a failed CLI
  authorization shows there too.
- Dialog test (op-broker's dialogs run in the guest, shown on your screen
  through the VM's display):

  ```sh
  vmssh 's=$(systemctl show -p ExecStart --value sbx-svc-op-broker | grep -o "/nix/store/[^ ;]*op-broker-guest-start" | head -n 1);
    p=$(grep -o "/nix/store/[^\"]*/bin/sbx-prompt" $(grep -o "/nix/store/[^ ]*op-broker-guest.json" "$s"));
    env $(grep -o "FONTCONFIG_FILE=[^ ]*" "$s") GSK_RENDERER=cairo XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-0 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/sbx/bus/bus \
      "$(grep -o "/nix/store/[^ ]*/bin/zenity" "$p")" --info --text "op-broker dialog test"'
  ```

  A window must appear on the host; an error printed here is why op-broker's
  prompts answer `denied` without one.

**3. The browser's side** (step 1 works, the browser doesn't):

```sh
pid=$(pgrep -u app-$b -n)
sudo nsenter -t "$pid" -m -- ls -la /run/sbx/op                                   # the socket, seen from the sandbox
sudo nsenter -t "$pid" -m -- ls -la /home/app-$b/.mozilla/native-messaging-hosts  # Firefox, Zen
sudo nsenter -t "$pid" -m -- ls -la /etc/chromium/native-messaging-hosts          # Chromium family
```

No `/run/sbx/op` → the browser started before `/run/op-broker` existed: restart
it. Then trigger a fill and read the extension's view: Firefox —
`about:debugging` → This Firefox → op-broker → Inspect (console), and the
Browser Console (Ctrl+Shift+J) for `op-broker-native-host: …` lines (why the
native host couldn't reach the broker) or "No such native application
com.otisroot.op_broker" (manifest not found); Chromium —
`chrome://extensions` → Developer mode → op-broker → *service worker* (console:
"Specified native messaging host not found" = manifest), and `journalctl -b -u
sandbox-$b | grep op-broker-native-host`.

## Decisions (the former open questions)

1. **1Password's authorization of the CLI:** desktop-app integration (not a
   service account), with 1Password's own polkit prompt answered by real system
   authentication on the host, as above, and system-authentication unlock too.
   Container: not possible (above), so op-broker defaults to on only where
   1Password runs in its VM.
2. **Probing:** `no-match` stays dialog-free per request, but probing shows a
   rate-limited notice (*Probing notice*).
3. **Firefox signing:** handled separately (Firefox Developer Edition, which
   honours `xpinstall.signatures.required = false`, with op-broker force-installed).
4. **"Allow until it stops":** kept as is.
5. **Subdomain matching:** kept as the default, and labelled in the chooser and
   the dialog.

## Open questions

1. Container: implement a 1Password container without user/pid namespaces
   (setuid-root bubblewrap limited to app-onepassword, or the root runScript
   building the sandbox), so op-broker and system auth work there too? It weakens
   the container (host pid namespace; a privileged bwrap) for the one app that
   holds the vault; the VM already provides both.
2. Thresholds: 4 sites / 2 min, one notice per 10 min, block for 1 h — adjust
   after living with it?

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
  `authorizeSshAgent`. From `resources/app.asar.unpacked/index.node`'s symbols
  and disassembly (`nm`, `objdump`): `op_system_auth::linux::challenge_with_action`
  (subject `Subject::new_for_owner(std::process::id())`, `CheckAuthorization`
  with details), `is_user_polkit_owner` (`EnumerateActions`, owner annotation vs
  the user name), `get_system_connector` (`is_owned_by_root` on the system bus
  socket's directory), `op_sys_info::process_information::linux::{is_owned_by_root,
  add_root_ownership_checks, verify_process_and_parent_permissions}` (fstat
  uid/gid/mode, FUSE `statfs` check, the `onepassword` group).
- polkit 127 sources: `polkitbackendinteractiveauthority.c` (callers may check
  other identities' subjects or pass details only as root or an action owner;
  agents may be registered for a unix-process subject, by root for any process;
  agent lookup is by exact subject, then the subject's session;
  `AuthenticationAgentResponse2` is root-only and must name an offered identity),
  `polkitbackendsessionmonitor-systemd.c` (a process without a session falls back
  to its user's display session: `sd_uid_get_display`), `polkitunixprocess.c`
  (subjects compare by pid and start time), `polkitagenthelper-pam.c` and NixOS's
  socket-activated `polkit-agent-helper`.
- crosvm `src/crosvm/sys/linux/config.rs`: a shared dir's default uid map is
  `0 <crosvm's euid> 1` (host root unmapped in the fs device's namespace).
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
