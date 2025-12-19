# ydotool - Generic Linux command-line automation tool
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
{
  programs.ydotool.enable = true;

  # Create the 'hidraw' group for ydotool
  users.groups.hidraw = { };

  # Add user to necessary groups for ydotool
  users.users.${username}.extraGroups = [
    "ydotool"
    "hidraw"
  ];

  # Provide custom udev rules for hidraw devices
  services.udev.extraRules = ''
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", GROUP="hidraw", MODE="0660"
  '';
}
