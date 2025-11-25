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
    persistence.user.large = [
      ".local/share/${config.app.name}"
    ];

    # Additional input device access for games
    nixpakModules = [
      ({ config, lib, ... }: {
        bubblewrap.bind.dev = [
          "/dev/input"   # Game controllers
          "/dev/uinput"  # Input emulation
        ];
      })
    ];
  };
}
