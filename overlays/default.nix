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
  #
  # xdg-dbus-proxy-sbx: the proxy every sandbox's session-bus filter runs
  # (nixpak's inner one, lib/backends/nixpak-pkg.nix; a VM's host-side one,
  # lib/vm/instance.nix), with --own-numbered=NAME added: owning
  # NAME-<digits>[-<digits>...] and nothing else, for tray icons
  # (lib/features/system-tray.nix). The proxy's own test suite, with that
  # option's cases, runs at build time. The crossuid one has it too: a
  # dedicated app's bridge applies the same filter arguments.
  xdg-dbus-proxy-crossuid = final: prev: {
    xdg-dbus-proxy-sbx = prev.xdg-dbus-proxy.overrideAttrs (old: {
      pname = "xdg-dbus-proxy-sbx";
      patches = (old.patches or [ ]) ++ [ ./xdg-dbus-proxy-own-numbered.patch ];
      doCheck = true;
      # The tests start `dbus-daemon --session`, which looks for its config
      # in /etc: point it at the package's own.
      preCheck = (old.preCheck or "") + ''
        export PATH=${
          prev.writeShellScriptBin "dbus-daemon" ''
            args=()
            for a in "$@"; do [ "$a" = --session ] || args+=("$a"); done
            exec ${prev.dbus}/bin/dbus-daemon \
              --config-file=${prev.dbus}/share/dbus-1/session.conf "''${args[@]}"
          ''
        }/bin:$PATH
      '';
    });
    xdg-dbus-proxy-crossuid = final.xdg-dbus-proxy-sbx.overrideAttrs (old: {
      pname = "xdg-dbus-proxy-crossuid";
      patches = old.patches ++ [ ./xdg-dbus-proxy-crossuid.patch ];
    });
  };
}
