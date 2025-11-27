# Game controllers and specialized input devices
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, ... }: {
      bubblewrap.bind.dev = [
        "/dev/input"
        "/dev/uinput"
      ];
    })
  ];
}
