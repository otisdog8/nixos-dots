{ lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    xxh
    ranger
    nix-index
    protonvpn-cli_2
    nixd
    jq
    vim
    wget
    git-crypt
    btop
    imagemagick
    polkit
    bat
    ripgrep
    git
    playerctl
    libsecret
    shellcheck
    bashate
    bash-language-server
    shfmt
    ncdu
  ];

 
  programs.zsh = {
    syntaxHighlighting = {
      enable = true;
    };
    enable = true;
    ohMyZsh = {
      enable = true;
    };
  };
  environment.pathsToLink = [ "/share/zsh" ];

  environment.variables = { EDITOR = "nvim"; VISUAL = "nvim"; };
  environment.enableAllTerminfo = true;
}
