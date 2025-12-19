{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      _:
      {
        bubblewrap.bind.ro = [
          "/run/current-system/sw/bin"
        ];
      }
    )
  ];
}
