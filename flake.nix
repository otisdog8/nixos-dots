{
  description = "A template that shows all standard flake outputs";

  # Inputs
  # https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix3-flake.html#flake-inputs

  # Work-in-progress: refer to parent/sibling flakes in the same repository
  # inputs.c-hello.url = "path:../c-hello";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-bwrapper.url = "github:Naxdy/nix-bwrapper";
    ccusage = {
      url = "github:ccusage/ccusage";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpak = {
      url = "github:otisdog8/nixpak/sandbox-xdg-runtime-dir";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    xdg-desktop-portal-src = {
      url = "github:otisdog8/xdg-desktop-portal/fallback-improvements-120";
      flake = false;
    };
    nixpkgs-older.url = "github:NixOS/nixpkgs?rev=3e042434c17eff8ed5528faa4c4503facc2bdf6c";
    nixpkgs-otisdog8.url = "github:otisdog8/nixpkgs/marvin";
    # Fresher, still cache-built channel for fast-moving packages (e.g. claude-code).
    # Tracks more closely than nixos-unstable without master's source-build risk.
    nixpkgs-unstable-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nix-minecraft = {
      url = "github:Infinidoge/nix-minecraft";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    hyprland = {
      url = "github:hyprwm/Hyprland/v0.55.4?submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    Hyprspace = {
      url = "github:KZDKM/Hyprspace";

      # Hyprspace uses latest Hyprland. We declare this to keep them in sync.
      inputs.hyprland.follows = "hyprland";
    };
    hyprsplit = {
      url = "github:shezdy/hyprsplit/main";
      inputs.hyprland.follows = "hyprland";
    };
    rose-pine-hyprcursor = {
      url = "github:ndom91/rose-pine-hyprcursor";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wezterm-flake.url = "github:wez/wezterm?dir=nix&rev=4506a7648e2ebef266225c1acdcd79967a4fc73b";
    wezterm-flake.inputs.nixpkgs.follows = "nixpkgs";
    nix-warez.url = "github:edolstra/nix-warez?dir=blender";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpak,
      nixos-hardware,
      chaotic,
      impermanence,
      lanzaboote,
      home-manager,
      zen-browser,
      hyprland,
      hyprsplit,
      Hyprspace,
      wezterm-flake,
      ...
    }@inputs:

    let
      inherit (self) outputs;
      stateVersion = "24.05";
      helper = import ./lib { inherit inputs outputs stateVersion; };
    in
    {
      overlays = import ./overlays { inherit inputs; };

      homeConfigurations = {
        "jrt@constitution" = helper.mkHome {
          hostname = "constitution";
          username = "jrt";
        };
        "jrt@matthew" = helper.mkHome {
          hostname = "matthew";
          username = "jrt";
        };
      };

      nixosConfigurations = {
        constitution = helper.mkNixos {
          hostname = "constitution";
          stateVersion = "24.05";
        };
        excelsior = helper.mkNixos {
          hostname = "excelsior";
          stateVersion = "24.05";
        };
        recusant = helper.mkNixos {
          hostname = "recusant";
          stateVersion = "24.05";
        };
        munificent = helper.mkNixos {
          hostname = "munificent";
          stateVersion = "24.05";
        };
        arquitens = helper.mkNixos {
          hostname = "arquitens";
          stateVersion = "24.05";
        };
        carrack = helper.mkNixos {
          hostname = "carrack";
          stateVersion = "24.05";
        };
        galaxy = helper.mkNixos {
          hostname = "galaxy";
          stateVersion = "25.05";
        };
        # Portable, encrypted, roaming USB workstation. Mint with
        # `nix run .#mint-usb -- /dev/sdX`.
        liveusb = helper.mkNixos {
          hostname = "liveusb";
          stateVersion = "25.05";
        };
      };

      # USB minting / upgrading helpers (run from the workstation).
      apps.x86_64-linux =
        let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
          mkApp = pkg: {
            type = "app";
            program = "${pkg}/bin/${pkg.name}";
          };

          mint-usb = pkgs.writeShellApplication {
            name = "mint-usb";
            runtimeInputs = [
              inputs.disko.packages.x86_64-linux.disko-install
              pkgs.util-linux
            ];
            text = ''
              if [ "$#" -ne 1 ]; then
                echo "usage: nix run .#mint-usb -- /dev/sdX" >&2
                echo "WARNING: ERASES the target disk. Prompts for a LUKS passphrase." >&2
                exit 1
              fi
              dev="$1"
              echo "About to mint the liveusb onto $dev — ALL DATA ON IT WILL BE LOST."
              lsblk "$dev"
              read -r -p "Re-type the device path to confirm: " confirm
              [ "$confirm" = "$dev" ] || { echo "mismatch, aborting" >&2; exit 1; }
              exec disko-install --flake "${self}#liveusb" --disk main "$dev"
            '';
          };

          upgrade-usb = pkgs.writeShellApplication {
            name = "upgrade-usb";
            runtimeInputs = [
              pkgs.util-linux
              pkgs.cryptsetup
              pkgs.nixos-install-tools
            ];
            text = ''
              if [ "$#" -ne 1 ]; then
                echo "usage: nix run .#upgrade-usb -- /dev/sdX" >&2
                echo "Reinstalls the system closure on an already-minted stick, keeping /persist." >&2
                echo "(Day-to-day, booting the stick and 'nixos-rebuild switch --flake .#liveusb' is simpler.)" >&2
                exit 1
              fi
              mnt="$(mktemp -d)"
              cleanup() { umount -R "$mnt" 2>/dev/null || true; cryptsetup close luks-upgrade 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
              trap cleanup EXIT
              cryptsetup open /dev/disk/by-partlabel/disk-main-luks luks-upgrade
              mount -o subvol=root,compress=zstd,noatime /dev/mapper/luks-upgrade "$mnt"
              mkdir -p "$mnt"/{nix,persist,boot}
              mount -o subvol=nix,compress=zstd,noatime /dev/mapper/luks-upgrade "$mnt/nix"
              mount -o subvol=persist,compress=zstd,noatime /dev/mapper/luks-upgrade "$mnt/persist"
              mount /dev/disk/by-partlabel/disk-main-ESP "$mnt/boot"
              nixos-install --root "$mnt" --flake "${self}#liveusb" --no-root-passwd
            '';
          };
        in
        {
          mint-usb = mkApp mint-usb;
          upgrade-usb = mkApp upgrade-usb;
        };

      devShells.x86_64-linux.default =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        in
        pkgs.mkShell {
          packages = with pkgs; [
            statix
            nixd
            markdownlint-cli
            nixfmt
          ];
        };

    };
}
