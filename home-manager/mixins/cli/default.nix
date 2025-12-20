{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  programs = {
    git = {
      enable = true;
      signing.signByDefault = false;
      lfs.enable = true;
      signing.key = "~/.ssh/id_ed25519.pub";
      settings = {
        user = {
          email = "me@rooty.dev";
          name = "Jacob Root";
          signingkey = "~/.ssh/id_ed25519.pub";
        };
        # Sign all commits using ssh key
        gpg.format = "ssh";
      };
    };
    ripgrep.enable = true;
    jq.enable = true;
    fastfetch.enable = true;
    eza.enable = true;
    bat.enable = true;
    btop.enable = true;
    ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks."*".addKeysToAgent = "yes";
    };
    zsh = {
      enable = true;
      history = {
        append = true;
        size = 100000;
        save = 100000;
        ignoreDups = true;
        ignoreSpace = true;
        expireDuplicatesFirst = true;
        share = true;
      };
      plugins = [
        {
          name = "vi-mode";
          src = pkgs.zsh-vi-mode;
          file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
        }
      ];
      shellAliases = {
        cd = "z";
      };
      enableCompletion = true;
      #autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      initContent = builtins.readFile ../../../config/zsh;
    };
    starship = {
      enable = true;
      settings = {
        command_timeout = 100;
      };
    };
    zoxide.enable = true;
  };
  services = {
    ssh-agent.enable = true;
    mpris-proxy.enable = true;
  };

  home.file.".profile".text = ''
    export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent
  '';
}
