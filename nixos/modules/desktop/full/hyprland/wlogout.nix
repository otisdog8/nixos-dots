# Wlogout power menu configuration
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.full.hyprland.wlogout;
in
{
  options.modules.desktop.full.hyprland.wlogout = {
    enable = lib.mkEnableOption "wlogout power menu";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.wlogout ];

    home-manager.users.${username} = {
      programs.wlogout = {
        enable = true;
        style = ''
          @define-color bar-bg rgba(0, 0, 0, 0);

          @define-color main-bg #24283b;
          @define-color main-fg #7aa2f7;

          @define-color wb-act-bg #bb9af7;
          @define-color wb-act-fg #b4f9f8;

          @define-color wb-hvr-bg #7aa2f7;
          @define-color wb-hvr-fg #cfc9c2;
          window {
              background-color: rgba(255,255,255,0);
          }

          button {
              color: white;
              background-color: @main-bg;
              outline-style: none;
              border: none;
              border-width: 0px;
              background-repeat: no-repeat;
              background-position: center;
              background-size: 10%;
              border-radius: 0px;
              box-shadow: none;
              text-shadow: none;
              animation: gradient_f 20s ease-in infinite;
          }

          button:focus {
              background-color: @wb-act-bg;
              background-size: 20%;
          }

          button:hover {
              background-color: @wb-hvr-bg;
              background-size: 25%;
              border-radius: 0px;
              animation: gradient_f 20s ease-in infinite;
              transition: all 0.3s cubic-bezier(.55,0.0,.28,1.682);
          }

          button:hover#lock {
              border-radius: 0px 0px 0px 0px;
              margin : 320px 0px 0px 819px;
          }

          button:hover#logout {
              border-radius: 0px 0px 0px 0px;
              margin : 0px 0px 320px 819px;
          }

          button:hover#shutdown {
              border-radius: 0px 0px 0px 0px;
              margin : 320px 819px 0px 0px;
          }

          button:hover#reboot {
              border-radius: 0px 0px 0px 0px;
              margin : 0px 819px 320px 0px;
          }

          #lock {
              background-image: image(url("${inputs.self}/images/lock_black.png"), url("/usr/share/wlogout/icons/lock.png"), url("/usr/local/share/wlogout/icons/lock.png"));
              border-radius: 0px 0px 0px 0px;
              margin : 400px 0px 0px 896px;
          }

          #logout {
              background-image: image(url("${inputs.self}/images/logout_black.png"), url("/usr/share/wlogout/icons/logout.png"), url("/usr/local/share/wlogout/icons/logout.png"));
              border-radius: 0px 0px 0px 0px;
              margin : 0px 0px 400px 896px;
          }

          #shutdown {
              background-image: image(url("${inputs.self}/images/shutdown_black.png"), url("/usr/share/wlogout/icons/shutdown.png"), url("/usr/local/share/wlogout/icons/shutdown.png"));
              border-radius: 0px 0px 0px 0px;
              margin : 400px 896px 0px 0px;
          }

          #reboot {
              background-image: image(url("${inputs.self}/images/reboot_black.png"), url("/usr/share/wlogout/icons/reboot.png"), url("/usr/local/share/wlogout/icons/reboot.png"));
              border-radius: 0px 0px 0px 0px;
              margin : 0px 896px 400px 0px;
          }
        '';
        layout = [
          {
            "label" = "lock";
            "action" = "~/.scripts/lock";
            "text" = "Lock";
            "keybind" = "l";
          }

          {
            "label" = "logout";
            "action" = "hyprctl dispatch exit 0";
            "text" = "Logout";
            "keybind" = "e";
          }

          {
            "label" = "shutdown";
            "action" = "systemctl poweroff";
            "text" = "Shutdown";
            "keybind" = "s";
          }

          {
            "label" = "reboot";
            "action" = "systemctl reboot";
            "text" = "Reboot";
            "keybind" = "r";
          }
        ];
      };
    };
  };
}
