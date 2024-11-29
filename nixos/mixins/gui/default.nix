{ inputs, lib, pkgs, ... }:
{
  imports = [ ./auth.nix ./desktop.nix ./desktop.nix ./fonts.nix ./plymouth.nix ./printing.nix ./sddm.nix ./theming.nix ];
  environment.systemPackages = with pkgs; [
    # Apps
    inputs.wezterm-flake.packages."${pkgs.system}".default
    lxqt.pcmanfm-qt
    protonvpn-gui
    code-cursor
    chromium
    vesktop
    kitty
    inputs.zen-browser.packages."${system}".default
    _1password
    _1password-gui
    steam
    kdePackages.ark
  ];
  hardware.graphics = {
    enable = true;
  };
  hardware.graphics.enable32Bit = true;

  hardware.flipperzero.enable = true;

  # chaotic.mesa-git.enable = true;
  services.udisks2.enable = true;
}
