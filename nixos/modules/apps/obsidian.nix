# Obsidian note-taking application

(import ../../../lib/apps.nix).mkApp (
  {
    config,
    lib,
    pkgs,
    ...
  }:
  {
    imports = [
      ../../../lib/features/chromium.nix
      ../../../lib/features/needs-gpu.nix
      ../../../lib/features/network.nix
      ../../../lib/features/xdg-desktop.nix
    ];

    config.app = {
      name = "obsidian";
      package = pkgs.obsidian;
      packageName = "obsidian";

      # Obsidian uses standard .config/obsidian location
      # chromium.basePath defaults to ".config/${name}" which is correct
      # Cache paths are also standard, so no overrides needed

      customOptions = config: {
        vaultPath = lib.mkOption {
          type = lib.types.str;
          default = "Documents/obsidian";
          description = "Path to Obsidian vault directory";
        };
      };

      customConfig =
        {
          config,
          lib,
          pkgs,
        }:
        {
          modules.apps.obsidian.sandbox.extraBinds = lib.mkIf config.modules.apps.obsidian.sandbox.enable [
            config.modules.apps.obsidian.vaultPath
          ];
        };
    };
  }
)
