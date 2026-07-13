{ inputs, ... }:
{
  otisdog8-packages = final: _prev: {
    otisdog8 = import inputs.nixpkgs-otisdog8 {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
  older-packages = final: _prev: {
    older = import inputs.nixpkgs-older {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
  unstable-small-packages = final: _prev: {
    unstable-small = import inputs.nixpkgs-unstable-small {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
  custom-packages = import ./custom-packages.nix { inherit inputs; };

  # Cross-uid D-Bus: patch xdg-dbus-proxy to drop the in-band uid from
  # "AUTH EXTERNAL <uid>", so the bus trusts the proxy's out-of-band SO_PEERCRED
  # instead. Lets the systemd-stash dedicated-uid backend run a jrt-side bridge
  # that relays a different-uid sandboxed app onto jrt's session bus (tray,
  # portals/screenshare, notifications). See lib/backends/systemd.nix (bridgeSock).
  #
  # Exposed as a SEPARATE package (not a global override of xdg-dbus-proxy) so it
  # doesn't force every reverse-dependency (plasma-workspace, flatpak, portals, …)
  # to rebuild — only the bridge in systemd.nix consumes it.
  xdg-dbus-proxy-crossuid = _final: prev: {
    xdg-dbus-proxy-crossuid = prev.xdg-dbus-proxy.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./xdg-dbus-proxy-crossuid.patch ];
    });
  };
}
