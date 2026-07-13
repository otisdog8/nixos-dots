# 1Password → dedicated-uid sandbox — design & staged rollout

**Status: DESIGN ONLY. `auth.nix` is unchanged and 1Password still runs as `jrt`.**
Do NOT flip this in one shot — 1Password is the auth root *and* the integration hub;
a naive move to `app-1password` breaks browser unlock, SSH signing, and the `op` CLI
until each cross-uid channel is bridged. Stage it (below), validate on a non-critical
host first.

## Goal & threat model

Run the 1Password GUI + background service as a dedicated uid (`app-1password`) so its
vault material (`~/.config/1Password`, `~/.1password`) is **DAC-hidden from a
compromised `jrt`**. This is the one app where hiding-from-jrt is the whole point:
today a compromised jrt process can read the local vault cache and the unlocked-session
state. Same mechanism as the browsers (dedicated uid + stash), but 1Password is *inbound*
— everything else talks to it — so it's the hardest.

## What breaks, and the bridge for each (reuse this session's machinery)

| Channel | Today (all jrt) | After dedicated-uid | Bridge |
|---|---|---|---|
| **Vault data** | `~/.config/1Password`, `~/.1password` jrt-owned | owned by `app-1password`, jrt EACCES ✅ (the win) | stash under `/persist/sandbox/1password`, owner `app-1password` |
| **GUI display** | jrt Wayland socket | app-1password needs Wayland/GPU cross-uid | **solved** — the systemd backend's ACL socket-relay (used by zen/vesktop/…) |
| **Browser integration** (native messaging) | extension → NativeMessaging host → app socket, all jrt | browsers are `app-<browser>`, app is `app-1password` → socket is cross-uid AND 1Password attests the caller binary | **hardest.** Per-browser: relay 1Password's browser-support socket into each browser sandbox (doc-portal-style cross-uid relay), and keep the wrapped browser binary in `/etc/1password/custom_allowed_browsers`. N browsers × (socket relay + attestation). |
| **`op` CLI** (biometric/desktop unlock) | `op` as jrt talks to desktop app socket | cross-uid socket | relay the CLI-integration socket to jrt, OR accept manual `op signin` (degraded UX) |
| **SSH agent** | `~/.1password/agent.sock`, git/ssh as jrt connect | agent.sock owned by app-1password | relay agent.sock to a jrt-readable path (socket-relay pattern); point `SSH_AUTH_SOCK` at the relay |
| **polkit** | `polkitPolicyOwners = ["jrt"]` | action owner is now app-1password | set `polkitPolicyOwners = ["app-1password"]`; verify the unlock-via-system-auth prompt still authorizes |
| **kwallet/PAM** | login kwallet unlock | 1Password mostly uses its own vault, but the login-keyring bridge may matter | verify unlock at login still works; likely unaffected |
| **autostart** | hyprland `1password --silent` | becomes the sandbox launcher | swap the exec for the `1password` framework launcher |

## Reusable machinery already built this session

- **Cross-uid socket relay**: `setfacl -R -m u:<app>:rwX` on the session socket + a
  bind into the app's runtime dir (systemd backend, `lib/backends/systemd.nix`).
- **Cross-uid D-Bus bridge**: `pkgs.xdg-dbus-proxy-crossuid`, `.flatpak-info` identity.
- **Cross-uid document portal**: FUSE + `allow_other` fork — the template for relaying
  1Password's browser-support / CLI sockets across the uid boundary.

The 1Password browser-support socket relay is *structurally the same problem* as the
doc-portal bridge: expose a socket owned by uid A to a sandbox running as uid B, with
the far end able to attest the caller.

## Staged rollout (each phase independently deployable + revertible)

1. **Port to an mkApp module, GUI-only, behind a default-OFF option.** New
   `nixos/modules/apps/1password.nix`: `defaultBackend = "systemd"`,
   `sandbox.dedicatedUser = true`, storage = `.config/1Password` + `.1password`
   (persist stash, app-1password). Keep `programs._1password*` for the CLI wrapper /
   polkit / etc. Gate the whole switch behind `modules.apps.1password.dedicated`
   (default false) so nothing changes until explicitly enabled on a test host.
   Validate: GUI opens, unlocks, vault visible in-app; `sudo -u jrt cat
   ~/.config/1Password/...` → EACCES.
2. **SSH agent relay.** Relay `agent.sock` to jrt; repoint `SSH_AUTH_SOCK`. Validate:
   `ssh-add -l` and a git commit signed by the 1Password key both work.
3. **Browser integration bridge** (the risk center). One browser first (zen): relay the
   browser-support socket into the zen sandbox, confirm the extension connects and the
   binary passes attestation. Then fan out to brave/chromium/firefox.
4. **`op` CLI desktop integration.** Relay the CLI socket, or document the manual-signin
   fallback.
5. **Flip default + polkit owner**, retire the jrt-owned path, roll host-by-host.

## Recommendation

Land phase 1 behind the default-off flag whenever you want the GUI-only isolation to
start being testable; do NOT enable it fleet-wide until phases 2–3 are validated, since
browser unlock and SSH signing are daily-driver-critical. This doc + the socket-relay
and bridge code from this session are the whole toolkit; it's execution + validation
time, not new mechanism.
