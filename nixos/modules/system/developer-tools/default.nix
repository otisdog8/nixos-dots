# Developer tools configuration - Neovim, Cargo, direnv, GitHub Copilot, Claude Code, etc.
{ config, lib, pkgs, username, ... }:
let
  cfg = config.modules.system.developer-tools;
in
{
  options.modules.system.developer-tools = {
    enable = lib.mkEnableOption "developer tools and configurations";
  };

  config = lib.mkIf cfg.enable {
    # Persistence for developer tools
    environment.persistence."/persist" = {
      users.${username} = {
        directories = [
          ".cargo"                      # Rust toolchain
          ".config/nvim"                # Neovim configuration
          ".local/state/nvim/"          # Neovim state
          ".local/share/nvim/"          # Neovim data
          ".local/share/direnv"         # direnv cache
          ".config/github-copilot"      # GitHub Copilot
          ".claude"                     # Claude Code CLI
        ];
        files = [
          ".claude.json"                # Claude Code configuration
        ];
      };
    };

    environment.persistence."/cache" = {
      users.${username} = {
        directories = [
          ".cache/uv"                   # Python uv cache
        ];
      };
    };
  };
}
