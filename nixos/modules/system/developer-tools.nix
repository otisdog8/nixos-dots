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
        nodejs
        corepack # pnpm/yarn version manager via Node.js

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
        markdownlint-cli

        # Nix development
        nixd
        nixfmt-rfc-style

        # Python tools
        uv

        # Container tools
        dive

        # JavaScript/TypeScript tools
        prettierd
        eslint

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
            ".local/share/pnpm" # pnpm global store
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
            ".npm" # npm cache
            ".cache/pnpm" # pnpm cache
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
      codex.enable = lib.mkDefault true;
      gsd.enable = lib.mkDefault true;
      opencode.enable = lib.mkDefault true;
      nixvim.enable = lib.mkDefault true;
    };
  };
}
