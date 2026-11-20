# NVIDIA graphics configuration
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.modules.system.hardware.nvidia;
  # NVIDIA's packaging (flake input nixpkgs-nvidia): their production branch
  # reaches it well before nixpkgs' nvidiaPackages.
  nvidiaPkgs = import inputs.nixpkgs-nvidia {
    inherit (pkgs) lib stdenv pkgsi686Linux;
    inherit (pkgs) callPackage;
    inherit (config.boot.kernelPackages) kernel kernelModuleMakeFlags;
  };
  # NVIDIA's packaging builds no nvidia-persistenced (passthru.persistenced is
  # null), which the NixOS module runs for hardware.nvidia.nvidiaPersistenced
  # (galaxy): nixpkgs' own builder, from NVIDIA's tag of the driver's version.
  # One hash per release; add the new one with a driver bump.
  persistencedHashes = {
    "620.70.06" = "sha256-FpGzhArrvR1nEt8lKDzNEnbvHvGP36gL1dINvpDAkpA=";
  };
  fixDriver =
    driver:
    driver.overrideAttrs (old: {
      # Its builder installs only firmware/gsp*.bin, but 620 split the GSP
      # image: RM also loads ucodes_ga10x.bin (ga10x is every GPU from Ampere
      # on, the 5090 included), and without it "RmFetchGspRmImages: No
      # firmware image found" and the GPU fails probe. Every firmware/*.bin.
      postInstall = (if old.postInstall or null == null then "" else old.postInstall) + ''
        if [ -n "''${firmware:-}" ]; then
          install -Dm644 -t $firmware/lib/firmware/nvidia/$version firmware/*.bin
        fi
      '';
      passthru = old.passthru // {
        persistenced = pkgs.callPackage (import
          "${pkgs.path}/pkgs/os-specific/linux/nvidia-x11/persistenced.nix"
          (driver // { persistencedVersion = driver.version; })
          (
            persistencedHashes.${driver.version}
              or (throw "nvidia.nix: no nvidia-persistenced hash for ${driver.version} in persistencedHashes")
          )
        ) { };
      };
    });
in
{
  options.modules.system.hardware.nvidia = {
    enable = lib.mkEnableOption "NVIDIA graphics drivers";

    openDrivers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use open-source NVIDIA drivers";
    };

    useBeta = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use beta NVIDIA drivers";
    };

    forceVideoDrivers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, force services.xserver.videoDrivers to exactly [ "nvidia" ]
        (single-GPU desktops). When false (default), only contribute "nvidia" and
        let the NixOS module system merge it with any open drivers the host
        declares (e.g. a roaming USB with modesetting + amdgpu + nvidia).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # NVIDIA's packaging fetches the driver only once its license is accepted.
    nixpkgs.config.nvidia.acceptLicense = true;

    services.xserver.videoDrivers =
      if cfg.forceVideoDrivers then lib.mkForce [ "nvidia" ] else [ "nvidia" ];

    hardware.nvidia = {
      open = cfg.openDrivers;
      package = fixDriver (if cfg.useBeta then nvidiaPkgs.bleeding_edge else nvidiaPkgs.latest);
      # The runfile packaging has no nvidia-settings, and the NixOS module
      # does not handle its absence.
      nvidiaSettings = false;
      modesetting.enable = true;
    };
  };
}
