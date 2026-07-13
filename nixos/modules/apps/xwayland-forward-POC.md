# XWayland forwarding to a dedicated-uid sandbox — PROOF OF CONCEPT

**Status: working POC, wired behind `modules.apps.<app>.sandbox.x11Forward` (default
false). Enabled on `zoom` as the test case.**

## Problem

A dedicated-uid sandbox app (runs as `app-<name>`, not `jrt`) that tries to use
XWayland gets:

```
Authorization required, but no authorization protocol specified
```

The compositor's XWayland belongs to `jrt`'s session; the app's uid has no cookie and
isn't in the X server's access list. This is why zoom was forced onto native Wayland
(where it then crashed a Qt6 child) and why Java/LWJGL games (lunar, prism) can't yet go
dedicated.

## POC approach — share jrt's XWayland via `xhost` localuser auth

Two moving parts, both already fit the systemd backend:

1. **Socket + DISPLAY** — the inner nixpak sandbox binds `/tmp/.X11-unix` and inherits
   `DISPLAY` (`bubblewrap.sockets.x11`, gated on `x11Forward` in `nixpak-pkg.nix`). The
   X socket lives in world-traversable `/tmp`, so no runtime-dir relay is needed (unlike
   the Wayland/dbus sockets).
2. **Auth without a cookie** — the launcher (which runs as `jrt`, so it can talk to
   jrt's X server) grants the app uid access with **server-interpreted localuser auth**:

   ```
   xhost +SI:localuser:app-<name>     # before `systemctl start --wait`
   xhost -SI:localuser:app-<name>     # in the launcher's EXIT/INT/TERM trap
   ```

   `SI:localuser:` uses the X server's `LocalUser` family — the server authorizes by the
   peer's *uid* over the local socket, so no `~/.Xauthority` cookie has to be copied
   cross-uid. Grant is scoped to exactly `app-<name>` and revoked when the launcher
   exits.

Net: `x11Forward = true` on a dedicated systemd app → its X clients reach jrt's
XWayland, windows appear as normal Wayland surfaces via the compositor.

## SECURITY CAVEAT (why this is a POC, not the default)

This **shares jrt's single X server**, and X11 has **no inter-client isolation**: a
client on that server can read other clients' input/output (keylogging, screen-scraping)
and inject events. So a compromised `x11Forward` app can attack every other X11/XWayland
client in the session. That partially undoes the point of the dedicated-uid boundary for
the X11 surface (Wayland, dbus, files, and the vault stay isolated; X11 does not).

Use `x11Forward` **only** for apps that (a) genuinely need XWayland and (b) can't do
native Wayland — currently just `zoom`. Do NOT blanket-enable it.

## Production path (not built here) — per-app rootless Xwayland

The isolated version runs a **separate `xwayland-satellite`** (rootless Xwayland for
wlroots/Hyprland) *as the dedicated uid*, giving the app its **own** X server that only
it can see, bridged to the compositor over the app's already-relayed Wayland socket. No
shared access list, full isolation. More setup (a per-app satellite process + its own
DISPLAY), so deferred until the POC proves the ergonomics are wanted.

## How to test

1. `nixos-rebuild switch`, launch zoom.
2. `journalctl -u sandbox-zoom.service -b` — expect NO "Authorization required" line,
   and a zoom window (XCB/XWayland) instead of the native-Wayland Qt6 crash.
3. Confirm the grant lifecycle: while zoom runs, `xhost` (as jrt) lists
   `SI:localuser:app-zoom`; after quitting, it's gone.
4. If zoom renders, the POC works and the same `x11Forward = true` can be trialed on the
   Java/LWJGL launchers (lunar/prism) — with the security caveat understood.
