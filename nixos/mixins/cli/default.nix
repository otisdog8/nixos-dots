{ lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    ast-grep
    uv
    unzip
    zip
    claude-code
    fd
    lazygit
    sd
    dig
    doggo
    iperf
    iotop
    nvtopPackages.full
    tcpdump
    nix-index
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
    shfmt
    ncdu
    kdePackages.ksshaskpass
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
    smartmontools
    python3
    lsof
    cloc
    zip
    gnumake
    meson
    ninja
    gcc
    pkg-config
    nvme-cli
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
  programs.nix-ld.enable = true;

  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
  environment.enableAllTerminfo = true;
}
