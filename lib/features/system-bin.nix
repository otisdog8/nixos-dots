{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  # The host's commands include other apps' sandbox wrappers (an agent running
  # another, claude inside sandbox-shell), and a nested bwrap needs its own
  # user namespace (lib/backends/bwrap-syscalls.nix).
  config.app.capabilities.nestedUserns = lib.mkDefault true;

  config.app.nixpakModules = [
    (_: {
      bubblewrap.bind.ro = [
        "/run/current-system/sw/bin"
        "/usr/bin/env"
      ];
    })
  ];
}
