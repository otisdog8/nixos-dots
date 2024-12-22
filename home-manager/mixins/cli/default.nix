
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
    signing.signByDefault = true;
    lfs.enable = true;

        signing.key = "~/.ssh/id_ed25519.pub";
      extraConfig = {
        # Sign all commits using ssh key
        commit.gpgsign = true;
        gpg.format = "ssh";
        user.signingkey = "~/.ssh/id_ed25519.pub";
      };
  };
  programs.ripgrep.enable = true;
  programs.jq.enable = true;
  programs.fastfetch.enable = true;
  programs.eza.enable = true;
  programs.bat.enable = true;
  programs.btop.enable = true;
  programs.emacs.enable = true;
  services.emacs.enable = true;
  services.ssh-agent.enable = true;

  home.file.".profile".text = ''
  export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent
  '';

  programs.ssh = {
    enable = true;
    addKeysToAgent = "yes";
  };
  services.gpg-agent.enable = true;
  services.gpg-agent.pinentryPackage = pkgs.pinentry-qt;
  programs.gpg.enable = true;
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
      k0s = "/var/lib/k0s/k0s";
    };
    enableCompletion = true;
    #autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initExtra = ''
      SOUND_PREFIX=${inputs.self}/sounds/
'' + builtins.readFile ../../../config/zsh;
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
