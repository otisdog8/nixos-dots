# CLI tools and shell configuration
{ config, lib, pkgs, username, ... }:
let
  cfg = config.modules.system.cli;
in
{
  options.modules.system.cli = {
    enable = lib.mkEnableOption "CLI tools and shell configuration";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
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
    environment.enableAllTerminfo = true;

    # Persistence for CLI tools
    environment.persistence."/persist" = {
      users.${username} = {
        directories = [
          ".local/share/zoxide/"
        ];
      };
    };
  };
}
