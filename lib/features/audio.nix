# Audio input and output (microphone + speakers)
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    (
      { lib, ... }:
      {
        bubblewrap.sockets = {
          pulse = true;
          pipewire = true;
        };
      }
    )
  ];
}
