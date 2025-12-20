# Developer tools configuration - Neovim, Cargo, direnv, GitHub Copilot, Claude Code, etc.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.system.developer-tools;
in
{
  options.modules.system.developer-tools = {
    enable = lib.mkEnableOption "developer tools and configurations";
  };

  config = lib.mkIf cfg.enable {
    # Development packages
    environment = {
      systemPackages = with pkgs; [
        # Language tools
        python3

        # Build tools
        gnumake
        meson
        ninja
        gcc
        pkg-config

        # Code search and manipulation
        ast-grep
        fd
        sd
        cloc

        # Version control
        lazygit

        # Shell tools
        shellcheck
        shfmt

        # YAML/Markdown tools
        yamlfmt
        yamllint
        nodePackages.markdownlint-cli

        # Nix development
        nixd
        nixfmt-rfc-style

        # Python tools
        uv

        # Container tools
        dive

        # Environment management
        direnv
      ];

      variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
      };

      persistence."/persist" = {
        users.${username} = {
          directories = [
            ".cargo" # Rust toolchain
            ".local/share/direnv" # direnv cache
            ".config/github-copilot" # GitHub Copilot
            # .claude and .claude.json moved to modules/apps/claude-code.nix
          ];
          files = [ ];
        };
      };

      persistence."/cache" = {
        users.${username} = {
          directories = [
            ".cache/uv" # Python uv cache
          ];
        };
      };
    };

    # Development tool configurations
    programs.direnv.enable = true;
    programs.nix-ld.enable = true;

    # Enable developer-facing apps by default
    modules.apps = {
      claude-code.enable = lib.mkDefault true;
      opencode.enable = lib.mkDefault true;
      nixvim.enable = lib.mkDefault true;
    };
  };
}
