# Handoff: the VM sandbox tier and everything around it (branch `vm-sandbox`)

For the next agent picking this up. Written 2026-09-26 by Claude (Opus 5.5) at the
end of a long session. Read this whole file before changing anything; then read
the design comments at the top of the files named below — they are the real
documentation, kept current, and more precise than this summary.

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

- Branch `vm-sandbox`, 39 commits ahead of `master` (`git log --oneline
  master..vm-sandbox`), head `0d6ea7c`. Nothing pushed, nothing deployed.
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
  per-VM user `sbx-gpu-<vm>` following the fork's DEPLOY.md. Windows always go
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
  (locked 0869ef9; GitHub `otisdog8/virtio-nvgpu` only has an older `dev` —
  switch the URL when the user pushes). Update: `nix flake update virtio-nvgpu`.
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

Never run on hardware: everything in the VM tier beyond the first CLI boot —
display/GPU (both stacks), relay services, D-Bus proxy, groups, grants, docs
share, FIDO, camera passthrough, nested nixpak, 1Password VM + polkit flow,
browser policies/extension installs, audio filter in real apps.

## 5. What the user should test first (suggest this order)

1. A GUI app in a VM on excelsior: `ark (vm)` (cross-domain) and `firefox (vm)`
   (virtio-nvgpu); `journalctl -u 'sandbox-vm-<app>*'`.
2. Audio: playback in a container app and a VM app; a mic prompt in a browser
   call; no audio in apps started before `sbx-broker` (expected).
3. 1Password in its VM: `docs/op-broker.md` hardware checklist (12 steps).
4. Firefox Developer Edition: extensions installed (about:addons), link
   forwarding (D-Bus name `org.mozilla.firefox_devedition` is inferred —
   `busctl --user list | grep -i mozilla`).
5. Camera in zoom (VM), FIDO key in a VM browser, `sbx-request grant-path`.

Expect bugs; fix them from the journal output the user pastes. Past fixes show
the typical kind: systemd specifier/quoting details (`%f` not `%I`; BindPaths
quotes each side separately), passt flag differences, crosvm seccomp gaps.

## 6. Open items / backlog

- **Screen capture in VMs:** waiting on the virtio-nvgpu agents
  (`docs/virtio-nvgpu-zero-copy-capture.md`: an "inject a host dma-buf"
  primitive). nixos-dots then builds the portal/PipeWire plumbing (host helper
  under the app's flatpak identity → guest PipeWire source node + guest
  ScreenCast portal backend). A copy-over-vsock fallback is possible without it.
- Native-PipeWire apps (incl. pipewire-jack) have no audio in sandboxes now; if
  one matters: restricted PipeWire socket for containers, virtio-snd for VMs.
- Container FIDO hotplug (containers still bind /dev/hidraw* at start).
- DRM-lease / compositor VM (low priority per user).
- 1Password in a namespace-less container (user leans no; VM is the answer).
- Old `lib/features/onepassword*.nix` BrowserSupport binds in browsers can go.
- Merged agent worktrees under `.claude/worktrees/` (4) can be removed once the
  user is happy (`git worktree remove`, delete `worktree-agent-*` branches).

## 7. User decisions on record

virtio-nvgpu only for GPU apps; prompts are desktop dialogs; agents sandbox =
declared projects + grants; builds allowed, no rebuilds; nested virt off;
1Password in its VM; broker prompt for each fill + 1Password's own prompt for the
CLI connection; system auth via host polkit; Firefox Developer Edition; Vimium;
probing notice thresholds 4 sites / 2 min, one per 10 min, block 1 h (accepted);
subdomain matching on but labelled; audio playback-only by default, microphone
capability + prompt (browsers, zoom, vesktop, obs-studio; not the captive-portal
browser); cameras by USB passthrough on approval.
