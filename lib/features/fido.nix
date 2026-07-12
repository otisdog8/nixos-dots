# FIDO/WebAuthn hardware security key support (raw /dev/hidraw*) — capability-based.
# NOTE: deliberately NOT implied by gui.nix. Import this only in apps that use
# security keys (browsers), so non-browser GUI apps don't get raw HID access.
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.fido = true;
}
