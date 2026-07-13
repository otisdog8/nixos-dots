# XWayland forwarding for dedicated-uid sandbox apps

The mechanism behind `modules.apps.<app>.sandbox.x11Forward` (default false). Used by
apps that genuinely need XWayland and can't run native Wayland under a dedicated uid:
**zoom** (Qt/XCB), **lunar-client** and **prismlauncher** (the Java/LWJGL Minecraft they
launch). It works, but shares jrt's X server — read the security caveat before enabling
it anywhere new.

## Problem

A dedicated-uid app (runs as `app-<name>`, not `jrt`) that tries to use XWayland gets:

```
Authorization required, but no authorization protocol specified
```

The compositor's XWayland belongs to `jrt`'s session; the app's uid has no cookie and
isn't in the X server's access list.

## Approach — share jrt's XWayland via `xhost` localuser auth

Two parts, both in the systemd backend:

1. **Socket + DISPLAY.** `x11Forward` turns on the `x11` capability, which binds
   `/tmp/.X11-unix` (see `lib/capabilities-nixpak.nix`; routed via `x11Forward` in
   `lib/backends/nixpak-pkg.nix`). `DISPLAY` comes from `gui.nix`'s `envOr "DISPLAY"
   ":0"`. NB: we deliberately do NOT use nixpak's `bubblewrap.sockets.x11` — that
   handler also binds `$XAUTHORITY`, and the launcher panics when it's unset; the `x11`
   capability binds only the socket, and auth comes from `xhost` below (no cookie).
2. **Auth without a cookie.** The launcher (runs as `jrt`, so it can talk to jrt's X
   server) grants the app uid access with server-interpreted localuser auth:

   ```
   xhost +SI:localuser:app-<name>     # before `systemctl start --wait`
   xhost -SI:localuser:app-<name>     # in the launcher's EXIT/INT/TERM trap
   ```

   `SI:localuser:` uses the X server's `LocalUser` family — the server authorizes by the
   peer's *uid* over the local socket, so no `~/.Xauthority` cookie is copied cross-uid.
   Scoped to exactly `app-<name>`, revoked when the launcher exits.

## SECURITY CAVEAT

This **shares jrt's single X server**, and X11 has **no inter-client isolation**: a
client on that server can read other clients' input/output (keylogging, screen-scraping)
and inject events. So a compromised `x11Forward` app can attack every other X11/XWayland
client in the session. Wayland, D-Bus, files, and the stash stay isolated per uid; the
X11 surface does not. Enable `x11Forward` ONLY for apps that need XWayland and can't do
native Wayland — do not blanket-enable it.

## The isolated alternative (not built)

The fully-isolated version runs a **per-app `xwayland-satellite`** (rootless Xwayland for
wlroots/Hyprland) *as the dedicated uid*, giving the app its own X server bridged to the
compositor over its already-relayed Wayland socket — no shared access list. It needs a
per-app satellite process + its own DISPLAY, so it's deferred; `x11Forward` is the
interim trade until it's worth building.
