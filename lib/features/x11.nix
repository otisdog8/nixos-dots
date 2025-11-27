# X11 socket for apps that need X11 compatibility
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, ... }: {
      bubblewrap.bind.ro = [
        "/tmp/.X11-unix"
      ];
    })
  ];
}
