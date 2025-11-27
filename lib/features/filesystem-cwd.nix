# Current working directory only
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, sloth, ... }: {
      bubblewrap.bind.rw = [
        (sloth.env "PWD")
      ];
    })
  ];
}
