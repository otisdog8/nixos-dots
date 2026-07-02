# CLI tools and shell configuration
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.system.cli;
in
{
  options.modules.system.cli = {
    enable = lib.mkEnableOption "CLI tools and shell configuration";
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = with pkgs; [
        # Archive tools
        unzip
        zip

        # Network tools
        dig
        doggo
        iperf
        tcpdump

        # System monitoring
        iotop
        nvtopPackages.full
        btop
        smartmontools
        lsof
        nvme-cli

        # File tools
        nix-index
        jq
        ncdu

        # Editors and text tools
        vim

        # Version control
        git
        git-crypt

        # General utilities
        wget
        imagemagick
        bat
        ripgrep
        playerctl
        libsecret
        screen

        # System tools
        polkit
        kdePackages.ksshaskpass

        # Kubernetes tools
        kubectl
        cilium-cli
        k9s
        fluxcd
        helm
        hubble
        authelia
        cloudflared

        # Filesystem tools
        nfs-utils
        bcachefs-tools
        clevis
        gocryptfs
        e2fsprogs
        fuse2fs

        # xterm-kitty terminfo so SSHing in from a kitty terminal (TERM=xterm-kitty)
        # doesn't break tmux/ncurses apps. Split output — does not pull in kitty.
        kitty.terminfo
      ];

      pathsToLink = [ "/share/zsh" ];
      enableAllTerminfo = false;

      # Persistence for CLI tools
      persistence."/persist" = {
        users.${username} = {
          directories = [
            ".local/share/zoxide/"
          ];
        };
      };
    };

    programs.zsh = {
      syntaxHighlighting = {
        enable = true;
      };
      enable = true;
      ohMyZsh = {
        enable = true;
      };
    };
  };
}
