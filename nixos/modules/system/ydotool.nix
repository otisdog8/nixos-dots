# ydotool - generic command-line input automation.
#
# OFF by default: membership in the `ydotool` group lets ANY process running as
# the user (including every same-uid sandbox) type into any window via ydotoold,
# which undoes the "no input group" hardening in nixos/default.nix. Enable per
# host only where something actually needs it.
#
# Injection goes through /dev/uinput only (the `ydotool` group); ydotool never
# needs to read /dev/hidraw*, so the user gets no hidraw group (that would expose
# physical keyboards).
{
  config,
  lib,
  username,
  ...
}:
let
  cfg = config.modules.system.ydotool;
in
{
  options.modules.system.ydotool.enable =
    lib.mkEnableOption "ydotool input injection (grants the user uinput injection)";

  config = lib.mkIf cfg.enable {
    programs.ydotool.enable = true;

    # uinput injection only. No hidraw group, no all-HID udev rule.
    users.users.${username}.extraGroups = [ "ydotool" ];
  };
}
