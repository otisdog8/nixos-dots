# Gaming application feature
{ config, lib, ... }:

{
  # Gaming apps are GUI apps that need GPU and network
  imports = [
    ./gui.nix
    ./needs-gpu.nix
    ./network.nix
  ];

  config.app = {
    # Games often have large data files
    persistence.user.large = lib.mkDefault [
      ".local/share/${config.app.name}"
    ];

    # Additional input device access
    sandbox.binds = lib.mkDefault [
      "/dev/input"   # Game controllers
      "/dev/uinput"
    ];
  };
}
