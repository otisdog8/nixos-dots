# FIDO/WebAuthn hardware security key support
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app.nixpakModules = [
    ({ lib, ... }: {
      # Bind hidraw devices for FIDO/U2F keys
      # Note: Requires user to be in 'hidraw' group (configured in ydotool.nix)
      bubblewrap.bind.dev = [
        "/dev/hidraw0"
        "/dev/hidraw1"
        "/dev/hidraw2"
        "/dev/hidraw3"
        "/dev/hidraw4"
        "/dev/hidraw5"
        "/dev/hidraw6"
        "/dev/hidraw7"
        "/dev/hidraw8"
        "/dev/hidraw9"
      ];
    })
  ];
}
