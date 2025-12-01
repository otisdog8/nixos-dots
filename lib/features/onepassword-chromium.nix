# 1Password browser integration for Chromium-based browsers
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];

  config.app = {
    nixpakModules = [
      ({ lib, sloth, ... }: {
        bubblewrap = {
          # Allow execution of the 1Password BrowserSupport wrapper
          bind.ro = [
            "/run/wrappers/bin/1Password-BrowserSupport"
          ];

          # Native messaging hosts directory for Chromium
          # Uses the chromium.basePath from the app config
          bind.rw = [
            (sloth.concat' sloth.homeDir "/${config.app.chromium.basePath}/NativeMessagingHosts")
            # 1Password socket for browser extension communication
            (sloth.concat' (sloth.env "XDG_RUNTIME_DIR") "/1Password-BrowserSupport.sock")
          ];
        };
      })
    ];

    # Note: The parent directory is already persisted by chromium.nix feature
  };
}
