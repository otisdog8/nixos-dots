
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
  programs.git = {
    enable = true;
    userEmail = "me@rooty.dev";
    userName = "Jacob Root";
  };
  programs.ripgrep.enable = true;
  programs.jq.enable = true;
  programs.fastfetch.enable = true;
  programs.eza.enable = true;
  programs.bat.enable = true;
  programs.btop.enable = true;
  programs.emacs.enable = true;
  services.emacs.enable = true;
  programs.zsh = {
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

  };
  programs.starship.enable = true;
  programs.starship.settings = {
    command_timeout = 100;
  };
  programs.zoxide.enable = true;
  programs.thefuck.enable = true;
  programs.neomutt.enable = true;
  services.mpris-proxy.enable = true;
}
