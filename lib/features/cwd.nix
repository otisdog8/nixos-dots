{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ sloth, ... }: {
      bubblewrap.bind.rw = [
        (sloth.env "PWD")
      ];
    })
  ];
}
