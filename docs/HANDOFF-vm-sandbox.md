# Handoff: the VM sandbox tier and everything around it (branch `vm-sandbox`)

For the next agent picking this up. Written 2026-09-26 by Claude (Opus 5.5) at the
end of a long session. Read this whole file before changing anything; then read
the design comments at the top of the files named below — they are the real
documentation, kept current, and more precise than this summary.

## Update 2026-10-03: lib/vm/core and the agent VM

Design: agent-auth's `docs/sandbox-design.md` (agent VMs, host daemons, remote
execution); this repo holds its NixOS side.
- `lib/vm/core/` — the pieces every crosvm VM shares: passt + its unit
  (`net.nix`, incl. `portFilter`: owner-matched iptables port limits for a
  passt with a dedicated uid), the VMM's sandbox and the jailed syscall filter
  (`hardening.nix`), shared-dir flags, vsock CID allocation (`cid.nix`: app VMs
  in [3, 3+2^28), the agent VM at 3+2^28). Extracted from `instance.nix` with no
  behaviour change: all 573 sandbox-vm-* units and the app guest evaluate to
  identical derivations on all eight hosts. (Whole-system drvPaths can't show
  that: anything embedding `${inputs.self}`, e.g. the sddm theme, changes with
  every edit.)
- `nixos/modules/system/agent-vm.nix` + `lib/vm/agent-guest.nix` — the agent VM:
  one always-on VM per host (system units, no desktop session), its own guest
  (tmpfs root; a btrfs data disk at /persist holding /var/lib, /nix/var,
  /var/log and the writable store overlay's upper layer, bound in place in the
  initrd; nix-daemon, userdbd, root SSH over vsock via `agent-vm ssh`). The
  disk is a sparse nodatacow image at `/large/agent-vm/disk.img`, or a
  dedicated block device (`modules.agentVm.disk.type = "block"`, e.g. an LV).
  Its own uids (`sbx-agentvm`, `sbx-agentvm-net`), network = internet + an
  allowlist with port limits (nixos/default.nix). Enabled on excelsior only, for bring-up.
  **Never run on hardware yet.** Built: guest system, units.

## Update 2026-09-29: Codex's capture bridge and gaming work, reviewed

After this handoff, Codex implemented VM screen sharing and tuned gaming VMs,
iterating on the real hardware (its traces are the `*.log` files in the repo
root; `docs/INVESTIGATION-prism-gpu-stall.md`). Claude then had five parallel
reviewers check it for correctness, architecture and security, fixed what they
found, and committed it: nixos-dots `9bc4446` (+ `b33a879`), and the nested
`vm-dbus-proxy` repo `c90621b`, `2610e82`, `34da25a` (flake input bumped).

**What exists now**
- `vm-dbus-proxy/` — a separate git repo nested here, pinned by flake input
  `vm-dbus-proxy` (`git+file:…?ref=main`: builds see only its COMMITTED `main`;
  commit there, then `nix flake update vm-dbus-proxy`, or iterate with
  `--override-input vm-dbus-proxy path:./vm-dbus-proxy`). It holds:
  - a guest D-Bus adapter (`sbx-dbus-proxy`, every VM with a bus): apps may
    negotiate fd passing locally; fd-bearing calls get NotSupported instead of
    crashing the app; the host relay mediates SASL and refuses fd negotiation;
  - the screen-capture bridge (`capture_proxy.py`, `capture_broker.py`,
    `capture/vm-capture.c`): host `-capture-bus` (desktop user) watches the
    app's ScreenCast portal flow and, after the host picker approved it, fetches
    the restricted PipeWire remote itself; host `-capture-broker` (uid
    `sbx-cap-<vm>`) consumes the stream and injects frames through virtio-nvgpu;
    guest `sbx-capture-broker` publishes them on a private per-share PipeWire.
- GPU window / per-process share per VM (`sandbox.vm.gpuMemoryMiB`,
  `gpuMemoryProcessPercent`; steam, prismlauncher, lunar-client at 16 GiB / 90%),
  built by `lib/vm/nvgpu.nix` `backendFor` (patched, self-testing backend
  variant; the stock backend at the defaults). Guest kmod patches (legacy
  syncobj handle, 32-bit compat ioctls), guest 32-bit graphics, Prism without
  GameMode, the VMM's UVM access for GPU-compute VMs, a passt assert fix.

**What the review found and fixed** (none critical or high; consent holds end
to end — no path found for a guest to get host screen content the user didn't
pick for that app):
- guest `/run/sbx` was owned by the app user (pre-existing, from the relay
  socket dirs): an app could replace root-used paths → now root-owned;
- a guest could make the desktop-user capture adapter hold unbounded memory →
  compact call records, caps, and MemoryMax/TasksMax on `-capture-bus`;
- the guest private PipeWire loaded plugin factories that load a
  client-named library (code execution as `sbx-capture`) → removed;
- restore tokens let a VM re-share without the picker → every share now
  forces the host picker (`persist_mode=0`);
- `-capture-broker` had every GPU node + video group → render node,
  nvidiactl/nvidia0, render group, syscall filter; `-capture-bus` confined like
  the relay;
- the VMM's UVM access narrowed (no video group, write-only, path hidden);
- functional: shares died after 5 s whenever the page stopped consuming
  (backgrounded tab) or a consumer relinked → frames are reclaimed after 500 ms
  instead; capture without a bus made the VM fail to start; the app's bus
  waited on the guest capture broker; the D-Bus adapter died on fd exhaustion;
  backend source patching was never built → rebuilt as `backendFor` and tested;
- the captive-portal browser no longer asks for ScreenCast (no capture bridge).

**Still open (known, accepted for now)** — details in §6:
- capture tokens pass through app-uid processes in the guest and the desktop
  user's adapter on the host (a gap vs virtio-nvgpu's "tokens stay secret";
  near-zero impact with one app per VM; real fix = a dedicated relay service
  between the two capture brokers);
- the guest `sbx-capture` account both runs the private PipeWire and holds
  `nvgpu-capture`; `--capture-fd` support exists but isn't wired (the node
  appears after `modprobe`, later than the broker starts);
- a window share ends on resize/format change; no explicit sync (tearing only
  in the guest's copy); no SHM fallback (consumer must import the DMA-BUF);
- the xdph patch (`nixos/modules/desktop/full/hyprland/patches/
  xdph-dequeue-busy-buffers.patch`, reviewed: correct) and xdph `--verbose`
  logging are wired only in `nixos/modules/desktop/full/hyprland/default.nix`,
  which other sessions own and haven't committed; `--verbose` logs every window
  title and should be dropped once capture is validated;
- the Prism stall (Xid 69) likely comes from the fork's unmap-by-VA defect; the
  bigger window only delays it. Upstreaming is requested in
  `docs/virtio-nvgpu-gpu-window-and-compat-brief.md` (window/share flags, kmod
  fixes, the leak, and two missing deployment facts);
- Codex's `*.log` traces in the repo root are untracked; delete when done.

**Validate next (in order)** — §5.8 has the concrete steps; as of 2026-09-30
items 1–4 there are unconfirmed (deferred behind the user's virtio-nvgpu work).

## 0. Ground rules the user set (keep them)

- **Security bar:** "an improvement over the current state", not perfection. Say
  plainly what a design does *not* protect against.
- **Never run `nixos-rebuild`** or change the running system. `nix eval` / `nix
  build` are allowed and expected. The user deploys and tests on hardware
  themselves and reports back (often by pasting journal output).
- **Don't edit `virtio-nvgpu/`** (the user's fork of virtio-nvgpu, checked out
  inside this repo; other agents work in it). Read it freely.
- **Another session's uncommitted work lives in the main checkout** — do not
  modify or commit: `nixos/hosts/excelsior/default.nix`,
  `nixos/modules/apps/claude-code.nix`, `nixos/modules/desktop/full/hyprland/`
  (incl. the staged-intent-to-add `lease/` files). Because of those
  intent-to-add entries, `git cherry-pick`/`merge` refuse in the main checkout;
  commit with an explicit pathspec (`git commit -- <paths>`), and bring other
  branches in as `git diff c^ c | git apply --index` + `git commit -C c -- $(git
  diff --name-only c^ c)` (in bash: zsh doesn't word-split).
- Commit in small, well-described commits on `vm-sandbox`; don't push. End commit
  messages with the session's attribution lines if your harness gives you any.
- The user prefers being told what's unverified over hedged claims, and wants a
  recommendation rather than a menu when a choice is theirs.

## 1. Where things stand

- Branch `vm-sandbox`, ~42 commits ahead of `master` (`git log --oneline
  master..vm-sandbox`). Nothing pushed, nothing deployed.
- **All eight hosts evaluate** (arquitens carrack constitution excelsior galaxy
  liveusb munificent recusant). Most units, guests and packages have been
  *built*.
- **Almost nothing has run on hardware.** The user confirmed only the very first
  VM milestone on excelsior (a CLI app booting in a VM, before GPU/display
  work). The agent environment has no `/dev/kvm`, no USB, no real session — so
  everything VM-side after that is build-verified only. Host-side Python pieces
  were tested locally (see §4).
- excelsior is the main machine: NVIDIA RTX (open driver 595.99.02), AMD CPU,
  Hyprland, kernel 7.2.7 with `CONFIG_RUST=y`, `lsm=landlock,yama,bpf`.

## 2. Architecture map

Apps are `mkApp` modules (`nixos/modules/apps/*.nix`, template `_template.nix`)
that compose `lib/features/*.nix` and declare **capabilities** (`lib/app-spec.nix`:
network, wayland, x11, gpu, audio, microphone, camera, fido, cwd, binds, dbus
policies, networkPolicy, …). Each capability is lowered by every backend.

**Two implementations per app, same data** (`lib/apps.nix`):
- container backend (`app.defaultBackend`): `nixpak` (in-session bwrap,
  `lib/backends/nixpak.nix` + `nixpak-pkg.nix` + `lib/capabilities-nixpak.nix`)
  or `systemd` (a root system unit that drops to the user or a dedicated uid,
  then runs the same nixpak bwrap inside; `lib/backends/systemd.nix`);
- VM (`lib/backends/vm.nix` → `lib/vm/instance.nix`).
`modules.apps.<app>.sandbox.mode = "container" | "vm"` picks which the command
runs (default `modules.sandbox.mode`). With `modules.sandbox.variants.enable`
(desktops/laptops) both are installed as "<App> (container)" / "<App> (vm)"
launcher entries. **Module-system rule:** backend choice is value-level, never
structural (`modules.apps` must not depend on its own values → infinite
recursion); follow the existing `lib.genAttrs … mkIf` patterns.

**VM tier** (`lib/vm/`, `nixos/modules/system/sandbox-vm.nix`):
- `instance.nix` (the heart, ~1600 lines, header comment explains all): one
  crosvm microVM per app (or per project dir for `cwd` apps, or per **group**),
  systemd units `sandbox-vm-<name>[-prep|-net|-wl|-gpu|-relay|-bus|-grantsfs|
  -grants|-docs|-camera]`, a launcher that starts the unit via polkit and runs
  the app over SSH-on-vsock with per-boot keys.
- `guest.nix` + `guest-graphics.nix`: ONE generic NixOS guest per host, booting
  the host's `/nix/store` over virtio-fs; the per-VM spec (a JSON store path on
  the kernel cmdline) says what to mount/start (`sbx-setup`).
- Storage: the app's stash entries bind-mounted into a per-tier tree, shared
  over crosvm's jailed virtio-fs, grafted back onto `~/path` in the guest; the
  guest user maps to the stash owner's uid (no chowning between modes).
- Network: passt over vhost-user, under `lib/netpolicy.nix` (VM default
  "internet": no LAN/host/tailnet), cgroup IP filter on the `-net` unit;
  `network.allowNames` via `sbx-dnsallow` (resolved's query monitor →
  `set-property IPAddressAllow=`), `lib/dnsallow.py`,
  `nixos/modules/system/sandbox-dnsallow.nix`.
- Graphics (`modules.sandbox.vm.graphics`, default `"auto"`): **virtio-nvgpu
  only for VMs with an app that has the `gpu` capability** (user's explicit
  wish), crosvm cross-domain (software rendering, no host GPU) for other GUI
  VMs. virtio-nvgpu built from the fork in `lib/vm/nvgpu.nix` (backend,
  nvgpu-wl-guest, patched crosvm c0474109, guest kmod); the backend runs as a
  per-VM user `sbx-gpu-<vm>` following the fork's DEPLOY.md. GPU VMs whose apps
  may ask the ScreenCast portal also get the fork's **capture injection**
  wired: `--inject-socket $rt/gpu/inject.sock --inject-uid <sbx-cap-<vm>>`, the
  socket ACLed to that helper user alone, and `/dev/nvgpu-capture` in the guest
  given to group `nvgpu-capture` — the programs on either side are not
  written yet (§6). Windows always go
  through a `wp_security_context_v1` socket (`lib/backends/wayland-security-context.py`).
- Host services into the guest: `vsock-relay.py` (guest listens on unix
  sockets, host end answers only its VM's CID): PulseAudio (filtered, below),
  D-Bus (`-bus` unit: xdg-dbus-proxy with the app's policy and a flatpak
  identity), the broker, grants, plus per-app `sandbox.vm.relays` hooks.
- Extras: live folder grants (`grants.py`, crosvm fs allowlist; needs the
  seccomp-patched `crosvm-fs.nix`), portal documents (doc portal by-app view
  over virtio-fs → file choosers work), FIDO keys (`fido-guest.py`: uhid virtual
  key relayed through the broker, CTAPHID channel-filtered), cameras (USB
  passthrough of video-class devices with `crosvm usb attach`, root unit
  `-camera`, only on approval), nested nixpak inside the guest
  (`sandbox.vm.nested`, off), generic hooks `sandbox.vm.{relays,guestBinds,
  guestServices(.root)}` and `modules.sandbox.vm.guestModules`.
- CLI: `sandbox-vm list | stop | status | camera NAME [attach|detach]`.

**Groups / agents** (`nixos/modules/system/sandbox.nix`, `sandbox-agents.nix`):
`modules.sandbox.groups.<g>` = several apps in one sandbox with shared
`projects`/`shareHome`. VM mode: one persistent VM. Container mode: a shared
persistent bwrap (`lib/backends/nixpak-group.nix`, user service
`sbx-group-<g>`, `lib/sbx-exec.py` passes the launcher's fds and signals) for
launches inside a project, the app's own sandbox elsewhere. `agents` group =
claude-code, codex, gemini-cli, gsd, opencode, ccusage (projects empty by
default → set `modules.sandbox.agents.projects` per host).

**Broker** (`lib/broker/broker.py`, `request.py`, `prompt.nix`;
`nixos/modules/system/sandbox-broker.nix`): user service `sbx-broker`, one
socket per sandbox (`$XDG_RUNTIME_DIR/sbx-broker/<name>.sock`; the socket is the
identity), desktop prompts (zenity; once / session ≤12 h / deny; root never
session-cached), rules. Ops: `exec` (as user, or root via run0), `grant-net`,
`grant-path`, `camera`, `fido`, `authenticate` (host polkit for a VM guest's
polkit agent), and the **PulseAudio filter**: each audio sandbox gets
`<name>.pulse` in front of pipewire-pulse — playback passes, recording needs the
`microphone` capability + a prompt, server-wide commands refused, shm negotiated
away. No sandbox gets PipeWire's native socket any more.

**1Password autofill** (`pkgs/op-broker/`, `nixos/modules/apps/op-broker.nix`,
design + threat model + decisions + hardware checklist in `docs/op-broker.md`):
extension → native host → per-browser socket → broker → `op` → 1Password app;
each fill approved in a dialog; probing notice; subdomain matches labelled.
**1Password runs in its VM by default** (`onepassword.nix`, commit 0d6ea7c):
only there can the app accept `op` and do system auth (in-guest polkit +
`lib/vm/polkit-agent.py` → broker `authenticate` → host hyprpolkitagent). In
the nixpak container it provably can't (user/pid namespaces break 1Password's
peer checks — see the doc). op-broker is on by default wherever 1Password is in
its VM.

**Browsers** (`lib/browser-settings.nix`, `nixos/modules/apps/{firefox,zen-browser,
chromium,ungoogled-chromium,brave,captive-browser-chromium}.nix`): declarative
policies (telemetry off, built-in password managers off, DoH off, …), Vimium +
uBlock defaults, op-broker's extension force-installed and the official
1Password extension blocked when op-broker serves the browser. `firefox` is
**Firefox Developer Edition** now (unsigned XPI support); its profile was and is
ephemeral.

**Other:** nested virtualization off by default (`nixos/modules/system/virt.nix`).

## 3. How to work here

- Nix builds go to a chroot store at `~/.local/share/nix/root/nix/store`
  (outputs are not under `/nix/store` directly; resolve symlinks against that
  prefix when inspecting).
- Evaluate all hosts:
  `for h in arquitens carrack constitution excelsior galaxy liveusb munificent recusant; do nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath; done`
- Build specific pieces with `nix build --impure --expr 'let c = (builtins.getFlake
  "git+file:///home/jrt/Documents/nixos-dots").nixosConfigurations.excelsior.config;
  in [ c.systemd.units."sandbox-vm-firefox.service".unit c.modules.sandbox.vm.guest.config.system.build.toplevel ]'`.
  Scenarios: `.extendModules { modules = [ { … } ]; }`.
- `virtio-nvgpu` flake input is `git+file:///…/virtio-nvgpu?ref=display-passthrough`
  (locked f78961b, 2026-10-01; `heavyfix`, the 2026-09-30 perf checkpoint cc9a481,
  is merged into it): prefaulted 2 MiB guest RAM (crosvm patch 0011, passed as
  `--prefault-memory` to virtio-nvgpu VMs; `modules.sandbox.vm.prefaultMemory`),
  pump/session latency fixes, the backend's 100 µs EEVDF slice (its default) and
  the tuning knobs (DEPLOY.md "Tuning", "vCPU placement"). Game VMs take the
  measured ones through `sandbox.vm.tuning = "game"` (steam, prismlauncher,
  lunar-client; `gameTuning` in instance.nix): the VMM under `chrt --other
  --sched-runtime 100000`, one core-scheduling cookie for VMM + backend
  (`coresched new`, then a root ExecStartPost copies it to the backend),
  `--cpu-affinity` from the fork's `rig/pin-layout.sh N smt` (nvgpu.nix
  `pinLayout`; unpinned when it has no layout), and `transparent_hugepage=always`
  + `modules_load=ntsync` in the guest. Not taken: `--vram-limit`, a host C-state
  cap, `--core-scheduling=false` outright (a side-channel trade), Hyprland
  `render:direct_scanout` (the other session's file). It
  has the window flags (`--window-size`, `--window-owner-share`, passed from
  `sandbox.vm.gpuMemoryMiB`/`gpuMemoryProcessPercent` by `nvgpu.nix`
  `windowArgs`) and our former guest-driver fixes, so nixos-dots patches nothing
  in the fork any more. Earlier pins: 0869ef9, 2eec306 (capture injection); GitHub `otisdog8/virtio-nvgpu`
  only has an older `dev` — switch the URL when the user pushes). Update:
  `nix flake update virtio-nvgpu`, then rebuild `lib/vm/nvgpu.nix`'s four
  packages (crosvm's patch series lives in the fork and changes with it).
- Gotchas hit before: zsh doesn't word-split `$VAR` (use `bash -c`); AF_UNIX
  paths >108 bytes (use short dirs like `/run/user/1001/…` for local socket
  tests); `nixfmt` reflows lines (re-read before sed); NixOS group names ≤31
  chars; git-crypt `secrets.nix` in worktrees needs the key linked
  (`.git/worktrees/<name>/git-crypt/keys/default` → main repo's key).
- Local test recipes that worked: a real PulseAudio (`pulseaudio -n
  --daemonize=no --use-pid-file=no` with `module-native-protocol-unix` +
  `module-null-sink`, `DBUS_SESSION_BUS_ADDRESS` unset) driven by
  pactl/paplay/parecord through `Broker.serve_pulse`; bwrap works unprivileged
  here (the group container was smoke-tested inside an outer bwrap binding the
  chroot store over `/nix/store`). Unit tests: `pkgs/op-broker/tests`,
  `lib/vm/tests` (run in package checkPhases).

## 4. Verification status (be honest about it)

Tested locally: broker ops (fake prompt), PulseAudio filter (real server), CTAPHID
channel filter, grants hub logic + real crosvm fs allowlist, sbx-exec agent,
dnsallow parsing/matching, op-broker (45 tests), polkit agent (9 tests).

Also tested (2026-09-29 review): vm-dbus-proxy 56 tests (incl. a real
dbus-daemon passing an fd), the capture C helper's protocol tests (checkPhase),
the relay's SASL mediation (9 tests in its build), the patched GPU backend
variant's tests, and the guest private PipeWire config run locally (a consumer
linked, plugin factories refused).

**Confirmed by the user on hardware (2026-09-30):** Firefox (Developer Edition)
shows Vimium, uBlock Origin and op-broker's extension; ungoogled-chromium
showed only op-broker's (fixed since in `b5eb947`: Vimium and uBlock Origin
Lite now load unpacked from the store — re-check `chrome://extensions`);
microphone prompts work, including "Allow for this session"; `sbx-request exec`
works; nixvim in its VM works; notifications work; nested virtualization is off.
Not yet tested: file chooser, folder grants, security keys, camera.
2026-10-01: 1Password runs in its VM with the cross-domain display (no GPU) —
the first confirmed cross-domain VM, after the stray "crosvm" window
(`video=Virtual-1:d`) and launch-before-display race fixes (`7b03f32`). Its
log's "No virgl contexts available on host" is Mesa probing the GPU-less
virtio-gpu (harmless); the native-messaging manifests 1Password writes land in
the guest's tmpfs home. op-broker fills: not yet re-tested after `08362ba`.

Hardware: Codex ran GPU VMs (Prism, Lunar, Chromium) and Firefox screen-share
attempts on excelsior (logs in the repo root), but no outcome was confirmed as
working. Treat everything VM-side as unverified until the user confirms it:
display/GPU (both stacks), relay services, D-Bus adapter, groups, grants, docs
share, FIDO, camera passthrough, nested nixpak, 1Password VM + polkit flow,
screen capture, browser policies/extension installs, audio filter in real apps.

## 5. Everything that was added, and how to check it

This covers every commit on the branch (`git log --oneline master..vm-sandbox`);
§5.6 maps the commits to these rows. The user will verify all of this on
hardware. Go in this order: the first block
changes the running desktop on the next rebuild even if no VM is ever used.
Logs: `journalctl -b -u 'sandbox-*' -u 'sbx-*'`, `journalctl --user -u sbx-broker
-u 'sbx-group-*'`, and inside a VM `sandbox-vm status NAME`.

### 5.1 Changes you'll notice right after a rebuild

| What | Check | Working looks like |
|---|---|---|
| **Filtered audio** (`sbx-broker`'s `<name>.pulse`; no PipeWire socket in any sandbox) | play sound in a container app (e.g. steam, zen) | sound plays; `pactl list clients` shows it; an app started before `sbx-broker` is running has no sound (expected); restarting the broker needs an app relaunch |
| **Microphone prompt** (capability `microphone`: browsers, zoom, vesktop, obs-studio) | start a mic test in a browser call | a desktop dialog "use your microphone" (Allow once / session / Deny); denied → the app sees "access denied"; playback continues meanwhile |
| **No mic for the rest** (steam, prismlauncher, lunar-client, tetrio, blender, amazing-marvin, wine, captive browser) | try to record in one | refused without a prompt |
| **Firefox is Developer Edition** (command `firefox-devedition`, entry "Firefox Developer Edition") | launch it | starts (dark theme, beta branding); links opened from other apps reach the running window — if not, `busctl --user list \| grep -i mozilla` and fix `dbusName` in `nixos/modules/apps/firefox.nix` |
| **Browser policies** (`lib/browser-settings.nix`) | `about:policies` / `chrome://policy` | policies active; built-in password manager and card autofill off; DoH off; telemetry off |
| **Default search engine** DuckDuckGo (set once, changeable; Brave keeps Brave Search, captive browser none) | new window's search | DuckDuckGo |
| **Chromium-family wrapper flags**: one `--enable-features=WebRtcPipeWireCapturer,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder` + `--no-first-run` (previously a second `--enable-features` silently dropped Brave's own VA-API flags) | `chrome://gpu` in Brave/Chromium, a screen share in a call | video decode hardware-accelerated; screen sharing uses the portal picker |
| **Extensions**: uBlock Origin (Firefox/Zen), uBlock Origin Lite (Chromium), Vimium (Firefox, Zen, Chromium, Brave) | `about:addons` / `chrome://extensions` | installed and locked; ungoogled-chromium gets Vimium + uBlock Origin Lite unpacked from the store (`lib/chromium-extensions.nix`; the Web Store can't work there); none in the captive browser (by design). **Firefox confirmed 2026-09-30** |
| **1Password runs in its VM** (`onepassword.nix` default) and **op-broker is on** | start 1Password | its window appears (cross-domain display, software rendering: 1Password has no GPU access by design since `00681d8`); vault works; see 5.4 |
| **op-broker's extension** in the browsers it serves, official 1Password extension blocked | extensions page | "op-broker" present; the official one refused |
| **sbx-broker** user service | `systemctl --user status sbx-broker` | active; sockets under `$XDG_RUNTIME_DIR/sbx-broker/` (`*.sock`, `*.pulse`) |
| **"(container)" / "(vm)" launcher entries** (variants on desktops/laptops) | app launcher | each sandboxed app listed twice; the plain entry hidden |
| **Nested virtualization off** (`virt.nix`) | `cat /sys/module/kvm_amd/parameters/nested` | `0` |
| **New system users** | `getent passwd \| grep -E 'sbx-(gpu\|cap)-'` | `sbx-gpu-<vm>` (virtio-nvgpu backends) and `sbx-cap-<vm>` (capture helpers, unused until §6) |

### 5.2 The VM tier (`<app> (vm)` entries, or `sandbox.mode = "vm"`)

| Feature | Check | Working looks like |
|---|---|---|
| Boot + launch | a CLI app's `(vm)` variant, e.g. `nixvim` | runs in the terminal within a few seconds; `sandbox-vm list` shows it; exits → VM stops (unless persistent) |
| Per-project VMs (apps with the `cwd` capability outside a group: nixvim, sandbox-shell) | run it in two different directories | one VM per directory (`sandbox-vm-<app>@<path>`), each seeing only its own directory at the same path |
| VM size | `sandbox.vm.memory` / `vcpus` (defaults 4096 MiB / 4; groups 8192 / 8) | the guest has that much (`free`, `nproc` in a VM shell) |
| DNS inside VMs | resolve a tailnet/MagicDNS or LAN-only name from a VM | fails by design: VM guests use public resolvers (`modules.sandbox.vm.dns`, Quad9) through passt, not the host's resolved — except apps with `allowNames`, whose DNS is forwarded to the host's resolved |
| Storage | the app's data after switching container ↔ vm | same files both ways (stash shared, uid-mapped) |
| Display, no GPU (cross-domain) | `ark (vm)` | window on Hyprland, software rendering |
| Display + GPU (virtio-nvgpu, only apps with the `gpu` capability) | `firefox (vm)`, `zen (vm)` | window; `about:support` lists the NVIDIA GPU with hardware compositing/WebGL; video plays smoothly; the backend runs as `sbx-gpu-<vm>` (`journalctl -u sandbox-vm-firefox-gpu`) |
| X11 apps | an x11 app in a VM | window via xwayland-satellite |
| Network policy (VM default "internet") | from a VM app, reach a LAN/tailnet address | refused; internet works |
| DNS-name allowlists (`network.allowNames`, mode allowlist) | set one on an app, resolve + connect | only the allowed names' addresses connect (`journalctl -u sbx-dnsallow`) |
| Audio in VMs | play sound / use mic in a VM browser | as in 5.1 (same filter, over the vsock relay) |
| D-Bus / portals | notification, open a link from a VM app | notification shows; link opens on the host |
| File chooser | upload a file from a VM browser | the host picker; the chosen file is readable in the VM |
| Folder grants | inside the VM: `sbx-request grant-path ~/Documents/x` (add `--write` for rw) | prompt; then the folder appears at the same path in the VM |
| Groups / agents sandbox (VM mode) | set `modules.sandbox.agents.projects = [ "~/…" ]`; run `claude` inside a project, then outside | one shared VM `group-agents`; outside a declared project the launcher grants `$PWD` (prompt-free: running it there is the consent) |
| Escapes | in a sandbox: `sbx-request exec -- ls /`, `sbx-request exec --root -- id` | prompt each; root never remembered for the session |
| Network grants | `sbx-request grant-net 1.2.3.4` | prompt; then reachable until the sandbox stops |
| FIDO key | WebAuthn login in a VM browser (key plugged in any time) | a prompt once ("use your security key"), then the key blinks; works after replugging |
| Camera | start zoom `(vm)` | background prompt "use your camera"; the webcam appears in zoom; host apps can't use it until the VM stops; also `sandbox-vm camera zoom attach\|detach` |
| Nested nixpak | `modules.apps.<app>.sandbox.vm.nested = true` | the app still works (defence in depth; off by default) |
| Persistence | `sandbox.vm.persistent = true` | VM stays up after the app exits; `sandbox-vm stop NAME` |

### 5.3 Containers (the default mode)

| Feature | Check | Working looks like |
|---|---|---|
| Shared agents container | set agents `projects`, run two agents in a project | both inside one `sbx-group-agents` user service; Ctrl-C, resize, exit codes behave like a normal terminal app |
| Escapes/grants from containers | `sbx-request exec …` in e.g. claude-code | prompt; runs on the host |
| Network policy (systemd-backend apps; nixpak apps only warn — they run in your session, unenforceable there) | `sandbox.network.mode = "internet"` on one | LAN blocked, internet fine |
| DNS-name allowlists for containers | `sandbox.network = { mode = "allowlist"; allowNames = [ "example.com" ]; }` on a systemd-backend app | only example.com's addresses connect; `journalctl -u sbx-dnsallow` logs each addition |
| Group projects in container mode without a shared container | a group member outside a project | still gets the group's `projects` and `shareHome` binds in its own sandbox |

### 5.4 1Password + op-broker (full checklist: `docs/op-broker.md`)

1. Log in to 1Password (in its VM). Settings → Security → "Unlock using system
   authentication": turns on; lock + unlock → the host's polkit agent
   (hyprpolkitagent) asks for your password; Cancel keeps it locked.
   (Needs the host's hyprpolkitagent running: on 2026-10-01 it wasn't — its
   unit is `PartOf=graphical-session.target`, which this session never starts,
   and it stopped right after login, so pkcheck found no agent. Fix pending in
   the hyprland module: exec the agent from Hyprland instead of its unit.)
2. Settings → Developer → "Integrate with 1Password CLI": turns on.
   1Password's VM has `sandbox.vm.hostKeyring` (kwallet's Secret Service on its
   bus) so it can keep the 2FA "remember this device" token; no other VM does.
3. In a browser, on a login page, press the op-broker toolbar button / Ctrl+Shift+L:
   the first time, the host polkit agent asks to authorize the CLI; then
   op-broker's dialog (browser, item, username, vault, site) → Allow → fields
   filled, nothing submitted.
4. A login saved for `github.com` used on `gist.github.com`: the dialog says
   "SUBDOMAIN MATCH".
5. Visit 4+ sites with no saved login and trigger fills: one probing notice
   naming them, with "Block it for an hour".
6. If fills answer `unavailable`: the guest's journal (`op-broker` service) says
   why — most likely 1Password rejecting the copied `op` (see the doc's
   assumptions).

### 5.5 Configuration knobs added (for the user's reference)

- `modules.sandbox.mode` (`container`/`vm`), `modules.sandbox.variants.enable`;
  per app `sandbox.mode`, `sandbox.vm.{persistent,memory,vcpus,nested,
  cameraOnLaunch,relays,guestBinds,guestServices}`, `sandbox.network.{mode,allow,
  deny,allowDns,allowNames}`.
- `modules.sandbox.vm.{graphics,dns,user,guestModules}`; per app and per group
  `sandbox.vm.{gpuMemoryMiB,gpuMemoryProcessPercent}` / `groups.<g>.vm.{…}`.
- `modules.sandbox.groups.<g>.{apps,persistent,sharedContainer,projects,shareHome,
  network,vm}`, `modules.sandbox.agents.{enable,apps,projects,shareHome,network}`.
- `modules.sandbox.broker.{enable,rules,defaultRules,authActions}` — rules per
  sandbox name (`<app>` container, `vm-<app>`, `vm-group-<g>`, `group-<g>`), ops
  exec / grant-net / grant-path / camera / microphone / fido / authenticate.
- Capabilities: `microphone`, `camera` (new), `networkPolicy`; features
  `microphone.nix`.
- `modules.apps.<browser>.browser.{managePolicies,extensions,blockedExtensions,
  allowUnsignedExtensions,unpackedExtensions,searchEngine,homepage,
  disableDnsOverHttps,builtinPasswordManager,hardwareVideoDecoding,policies,
  recommendedPolicies}`.
- `modules.apps.op-broker.{enable,browsers,auth,prompt,match,limits,probe,…}`.
- `modules.system.virt.nestedVirtualization` (default off).

### 5.6 Commit map

| Commit(s) | Covered in |
|---|---|
| 429a163 — the user's own pending refactor, committed at the start: legacy backend dropped, **Wayland security-context sockets for all sandboxes**, race-free root binds (mount-helper) | not ours to verify beyond "containers still start and show windows" |
| 4f4366b, 847e93a, cd86b14, eeceba5, f81a41c | 5.2 (VM tier, variants, network policy, display, audio, D-Bus) |
| 796dc37, aaf8fb1, ee244c5 | broker: 5.1, 5.2, 5.4 |
| f718da8, b76e315 | groups/agents: 5.2, 5.3 |
| 31e66f2, a3c1884, b35517f, 07b07b5, 20d1a90, d8b70a7 | 5.2 (grants, FIDO, nested, file chooser; hooks are internal) |
| ed007ab, fee0953, e904cc0, a2c361e, e6959b3 | browsers: 5.1 |
| b610fd0, 3f09ac8, 407e8e9, 27a2064, 48a9ac4, a25518d, 8ca3789, 200379c, 0b830b7, 0d6ea7c | 1Password/op-broker: 5.1, 5.4 |
| 95807a9 | DNS allowlists: 5.2, 5.3 |
| 5f9e6f2, 97a39c0, 3597f21 | virtio-nvgpu versions, per-VM backend users, graphics auto, camera, capture plumbing: 5.1, 5.2, 5.7 |
| a787460, 44935c0 | audio: 5.1 |
| ce3b150, 16a28b2 and later docs | docs only |
| 9bc4446 (+ vm-dbus-proxy c90621b, 2610e82, 34da25a) — Codex's capture bridge and gaming GPU work, reviewed | 5.7, 5.8 |
| b33a879 — captive browser: no capture portals | 5.1 |
| f81a41c also: nested virtualization off by default (`virt.nix`) | 5.1 |

### 5.7 Screen sharing from GPU VMs (Codex's bridge, reviewed)

Apps with ScreenCast (browsers, zoom, vesktop, obs-studio; not the captive
browser) in a virtio-nvgpu VM. Steps in §5.8.

### 5.8 Validate next, in this order

Status (2026-09-30): items 1–4 are **UNCONFIRMED** — not yet run by the user,
deferred while other virtio-nvgpu changes land first. Re-run them after those
changes (a fork bump rebuilds the backend, crosvm and the guest module).

1. **[UNCONFIRMED] Rebuild and restart VMs fully** (the guest changed: root-owned
   `/run/sbx`, the D-Bus adapter, the capture broker). In a VM:
   `ls -ld /run/sbx` → root:root; `/run/sbx/broker.sock` → symlink to
   `relay/broker.sock`; `sbx-request exec -- true`, a FIDO login and (1Password
   VM) op-uplink still reach the broker; `sandbox-vm list` shows no
   `-capture-*` entries.
2. **[UNCONFIRMED] D-Bus adapter** (any VM app): notifications and file chooser work; an
   fd-passing action gets an error, not a crash; several apps in one VM keep
   their buses independently. Guest log: `journalctl -u sbx-dbus-proxy`.
3. **[UNCONFIRMED] Screen share** from Chromium/Firefox in a VM: the host picker appears
   (every time — no restore), the share shows moving content for 60 s; host
   `journalctl -u 'sandbox-vm-<app>-capture-*'` shows at most a few
   "reclaimed" lines and never "EGL modifier query unavailable" (that would
   mean the narrowed `-capture-broker` lacks a device or syscall); guest
   `journalctl -u sbx-capture-broker` shows WirePlumber linking the consumer.
   Then: background the page >10 s and return (must continue); share a window
   and resize it (expected to end — report it); cancel the picker; stop and
   re-share; close the browser, then the VM, mid-share — the host indicator
   must disappear each time. Stopping the guest `sbx-capture-broker` must not
   break the app's other D-Bus use.
4. **[UNCONFIRMED] Gaming VMs** (steam, prismlauncher, lunar-client at 16 GiB / 90%): Prism
   no longer logs `(Owner)` refusals or hits Xid 69 quickly — note whether the
   refusals merely come later (the fork's leak); Steam's 32-bit client starts;
   a CUDA workload in a compute VM registers its UVM pools (if crosvm logs
   EACCES/EPERM on RegisterUvmPool, re-add `rw` on `/dev/nvidia-uvm`, not the
   video group); Prism starts in VM and container modes.
5. Then the rest of §5.1–5.4 as before.

A VM whose app has exited stops (`sandbox-vm list` empties) unless it is
persistent: that is the expected lifecycle, not a crash.

Expect bugs; fix them from the journal output the user pastes. Past fixes show
the typical kind: systemd specifier/quoting details (`%f` not `%I`; BindPaths
quotes each side separately), passt flag differences, crosvm seccomp gaps.

## 6. Open items / backlog

- **Screen capture: implemented** (see the update at the top; the text below
  is the original design, kept for history — the implemented protocol lives in
  `vm-dbus-proxy/` and differs). Remaining: a dedicated relay service between
  the host and guest capture brokers so tokens never pass through app-uid or
  desktop-user processes; wire `--capture-fd` (open the node after `modprobe`,
  then drop `nvgpu-capture` from the guest `sbx-capture` user); keep shares
  alive across window resizes (pool/format changes); explicit sync; an SHM
  fallback; commit the xdph patch wiring (hyprland/default.nix, other session)
  and drop xdph `--verbose`.
- **Upstreamed** (2026-09-30, `heavyfix`): the window/share flags and both guest
  driver fixes — nixos-dots dropped its patches. The Prism window exhaustion was
  "in part a backend defect since fixed" (fork DEPLOY.md): steam/prism/lunar
  were then deliberately sized UP at the user's request (2026-10-01): 12 vCPUs
  (`smt` on six whole cores; the fork: at 16, which fills a CCD, no layout
  wins), 32 GiB, a 24 GiB window at 90%. Costs: RAM is committed whole at VM
  start (two game VMs = 64 of the host's 92 GiB); each window's WC zone may
  take ~18.5 GiB of the 5090's 32 GiB BAR1 (the backend warns at start), fine
  for games' tens of MiB but two heavy mappers at once could run BAR1 out. The
  VMM's MemoryMax is now RAM + 512 MiB + the window (the fork's sizing note).
- **Original capture design (historical):** The
  virtio-nvgpu side is done and hardware-tested by its agents: see
  `docs/virtio-nvgpu-zero-copy-capture.md` (our brief),
  `docs/virtio-nvgpu-zero-copy-capture-reply.md` (their answer), and the fork's
  `DEPLOY.md` "Capture injection" (normative wire format and rules),
  `SECURITY.md` §18, `ARCHITECTURE.md` §17, reference C code
  `rig/rig-tools/nvgpu-inject-test.c` (helper) and
  `rig/guest-image/tools/nvgpu-capture-import.c` (daemon). nixos-dots has wired
  the users, socket and node (commit 3597f21). Still to write:

  1. **The D-Bus problem (the crux).** A VM app reaches the host portal over the
     relayed session bus (guest `vsock-relay` socket → host `-bus` unit's
     xdg-dbus-proxy with the app's flatpak identity). The ScreenCast flow is
     CreateSession → SelectSources → Start (the host picker: the consent) →
     Response with `streams a(ua{sv})` (host PipeWire node ids) →
     `OpenPipeWireRemote` returning a **file descriptor**, which can't cross
     vsock; and the node ids mean nothing in the guest. Recommended approach: a
     **ScreenCast shim in the guest end of the D-Bus relay** that intercepts
     only `org.freedesktop.portal.ScreenCast` calls (parse D-Bus message headers;
     pass every other message through untouched), answers them itself as the
     portal would (Request/Session object paths, Response signals synthesized
     with the portal's sender name), and drives the real session through a
     private relay service to a host **capture client**. Alternative: let the
     calls through, make the host relay capture the fd from the method return
     (recvmsg) and hand it to the helper, and have the guest relay attach a
     guest PipeWire fd and patch node ids in the Response in place — fewer
     synthesized messages, more byte-level patching; judge which is less
     fragile.
  2. **Host capture client** (as the user, in a bwrap giving it the app's
     `.flatpak-info` like the `-bus` unit does, so the host portal attributes
     the request to the app and the picker names it): performs the portal
     session, gets the restricted PipeWire remote fd, consumes the stream with a
     DMA-BUF format offer (libpipewire in C, or GStreamer `pipewiresrc` via
     Python GI — C is more controllable), and passes each buffer's dma-buf fds
     over a unix socket (SCM_RIGHTS) to…
  3. **The host capture helper**, running as `sbx-cap-<vm>` (the only uid the
     backend accepts): HELLO, IMPORT per buffer (→ id + secret token), RELEASE
     when PipeWire drops a buffer; per frame, announce `(id, seq, timestamps,
     damage, crop, cursor)` to the guest daemon over a new relay service (never
     put tokens in argv/env/logs/files), hold the buffer until the daemon's
     `done` or a few-frame timeout, then requeue. xdph 1.4.1 attaches no
     SyncTimeline, so "announce only complete frames" suffices; optional explicit
     sync per DEPLOY.md. It can be merged with the capture client if the
     client's uid can be sbx-cap (it can't: the client needs the user's session
     bus) — keep them split.
  4. **Guest capture daemon** (an account in group `nvgpu-capture`, never the
     app's): opens `/dev/nvgpu-capture` + `/dev/dri/renderD128`,
     `NVGPU_CAPTURE_IOC_OPEN {render_fd, id, token}` → read-only dma-buf +
     layout (`driver/uapi/nvgpu_capture.h`), publishes a PipeWire **video
     source node** whose buffers are those dma-bufs (`SPA_DATA_DmaBuf`, the
     modifier), queues per announced frame, sends `done`. Needs PipeWire (+
     WirePlumber, or a static link policy) running in the guest for the app's
     user — the guest has none today.
  5. The shim returns the guest node's id in the Response and a connection to
     the guest PipeWire (restricted to that node if feasible) as the
     OpenPipeWireRemote fd.
  6. Cross-domain (non-GPU) VMs have no injection: a copy fallback (helper maps
     the buffer, frames over vsock, daemon uses MemFd buffers) is possible but
     heavy (~250 MB/s at 1080p30).
  Limits to respect (from the reply): 32 buffers / 1 GiB / 16 syncobjs per VM;
  buffers must be this GPU's nvidia-drm memory (a SHM/MemFd stream can't be
  injected; refuse or fall back to copying); the guest can write to its own
  stream's buffers (GPU mappings are read-write) — harmless to anyone else.
- Native-PipeWire apps (incl. pipewire-jack) have no audio in sandboxes now; if
  one matters: restricted PipeWire socket for containers, virtio-snd for VMs.
- Container FIDO hotplug (containers still bind /dev/hidraw* at start).
- DRM-lease / compositor VM (low priority per user).
- 1Password in a namespace-less container (user leans no; VM is the answer).
- Merged agent worktrees under `.claude/worktrees/` (4) can be removed once the
  user is happy (`git worktree remove`, delete `worktree-agent-*` branches).

## 7. User decisions on record

virtio-nvgpu only for GPU apps; prompts are desktop dialogs; agents sandbox =
declared projects + grants; builds allowed, no rebuilds; nested virt off;
1Password in its VM, without GPU access (software rendering; no virtio-nvgpu for
the vault's sandbox); broker prompt for each fill + 1Password's own prompt for the
CLI connection; system auth via host polkit; Firefox Developer Edition; Vimium;
probing notice thresholds 4 sites / 2 min, one per 10 min, block 1 h (accepted);
subdomain matching on but labelled; audio playback-only by default, microphone
capability + prompt (browsers, zoom, vesktop, obs-studio; not the captive-portal
browser); cameras by USB passthrough on approval.
