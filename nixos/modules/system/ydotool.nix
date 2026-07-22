# ydotool - generic command-line input automation (used by scripts/hotkeys).
#
# ydotool injects through /dev/uinput (writing a virtual device); it does NOT
# need to READ /dev/hidraw*. The old config added jrt to a `hidraw` group and
# opened ALL /dev/hidraw* (which includes physical keyboards) to it — a
# keylogging surface that also leaked into in-session sandboxed apps (they run
# as jrt and inherit its groups). That's removed: uinput access comes from the
# `ydotool` group that programs.ydotool wires up, and FIDO keys stay reachable
# via their per-device `uaccess` ACL, not a blanket group.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
{
  programs.ydotool.enable = true;

  # uinput injection only. No hidraw group, no all-HID udev rule.
  users.users.${username}.extraGroups = [ "ydotool" ];
}
