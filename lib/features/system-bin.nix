{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ ... }: {
      bubblewrap.bind.ro = [
        "/run/current-system/sw/bin"
      ];
    })
  ];
}
