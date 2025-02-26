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
    kdePackages.ksshaskpass
    jdk
    screen
    neovim
    kubectl
    cilium-cli
    k9s
    fluxcd
    helm
    hubble
    tcpdump
    authelia
    cloudflared
    imagemagick
    ncdu
    nfs-utils
    bcachefs-tools
    clevis
    nixfmt-rfc-style
    direnv
    dive
    podman-tui
    docker-compose
    podman-compose
    enscript
    ghostscript
    a2ps
    smartmontools
    python3
    lsof
    cloc
    zip
    gnumake
  ];

  programs.direnv.enable = true;

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

  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
  environment.enableAllTerminfo = true;
  virtualisation.containers.enable = true;
  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };
}
