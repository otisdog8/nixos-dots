{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  imports = [
    inputs.hyprland.homeManagerModules.default
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    plugins = [
      inputs.hyprsplit.packages.${pkgs.stdenv.hostPlatform.system}.hyprsplit
      # inputs.Hyprspace.packages.${pkgs.system}.Hyprspace
    ];
    systemd.variables = ["--all"];
    settings = {
      debug = {
        disable_logs = false;
      };
      "$mod" = "SUPER";
      "$home" = "/home/${username}";
      binde = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%-"
      ];
        # "$mod, tab, overview:toggle"
      bind = [
        "SUPER, V, exec, cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"
        "CTRL_ALT, l, exec, loginctl lock-session"
        "CTRL_ALT, t, exec, wezterm"
        "CTRL, Space, exec, rofi -show drun"
        "CTRL_SHIFT, q, exec, wlogout -b 2 -c 0 -r 0 -m 0 --protocol layer-shell"
        "ALT, tab, cyclenext"
        "ALT, F4, killactive"
        "ALT_SHIFT, F4, exec, hyprctl kill"
        "$mod, q, exec, wezterm"
        "$mod, m, fullscreen"
        "$mod_SHIFT, m, fullscreenstate, -1, 2"
        "$mod, p, pseudo"
        "$mod, s, togglefloating"
        "$mod, d, split:swapactiveworkspaces, current + 1"
        "$mod, g, split:grabroguewindows"
        "$mod, r, layoutmsg, togglesplit"
        "$mod, w, exec, killall -SIGUSR1 waybar"
        "CTRL_SHIFT, Space, exec, grimblast --freeze copysave area"
        ",XF86PowerOff, exec, wlogout -b 2 -c 0 -r 0 -m 0 --protocol layer-shell"
        ",XF86MonBrightnessUp, exec, brightnessctl s +5%"
        ",XF86MonBrightnessDown, exec, brightnessctl s 5%-"
        ",XF86AudioStop, exec, playerctl stop"
        ",XF86AudioStop, exec, playerctl stop"
        ",XF86AudioMedia, exec, playerctl play-pause"
        ",XF86AudioPlay, exec, playerctl play-pause"
        ",XF86AudioPrev, exec, playerctl previous"
        ",XF86AudioNext, exec, playerctl next"
        ",XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
      ] ++ (
        builtins.concatLists (builtins.genList (i:
            let ws = i + 1; key = ws - ws / 10 * 10;
            in [
              "$mod, ${toString key}, split:workspace, ${toString ws}"
              "$mod SHIFT, ${toString key}, split:movetoworkspacesilent, ${toString ws}"
            ]
          )
          10)
      ) ++ (
        builtins.concatLists (
          map (x: 
            [
              "$mod, ${x.a}, movefocus, ${x.b}"
              "$mod_SHIFT, ${x.a}, movewindow, ${x.b}"
              "$mod, ${x.c}, movefocus, ${x.b}"
              "$mod_SHIFT, ${x.c}, movewindow, ${x.b}"
              "$mod_CTRL, ${x.c}, resizeactive, ${x.d}"
              "$mod_CTRL, ${x.a}, resizeactive, ${x.d}"
              "$mod_ALT, ${x.c}, workspace, ${x.e}"
              "$mod_ALT, ${x.a}, workspace, ${x.e}"
              "$mod_ALT_SHIFT, ${x.c}, movetoworkspace, ${x.e}"
              "$mod_ALT_SHIFT, ${x.a}, movetoworkspace, ${x.e}"
            ]
          ) [ {a = "left"; b = "l"; c = "h"; d = "-20 0"; e = "r-1"; } {a = "right"; b = "r"; c = "l"; d = "20 0"; e = "r+1"; }  {a = "up"; b = "u"; c = "k"; d = "0 -20"; e="emptynm"; } {a = "down"; b = "d"; c = "j"; d = "0 20"; e = "previous_per_monitor"; } ]
        )
      );
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
      bindl = [
        ",switch:on:Lid Switch,exec,loginctl lock-session && touch /tmp/10midle && test $(cat /sys/class/power_supply/AC0/online) = 0 && sleep 1 && systemctl suspend"
      ];
      monitor = [
        ",highres,auto,1,bitdepth,10"
      ];
      exec-once = [
        "hyprpaper"
        "1password --silent"
        "kwalletd6"
        "polkit-agent-helper-1"
        "${pkgs.kdePackages.kwallet-pam}/libexec/pam_kwallet_init"
        "waybar"
        "nm-applet"
        "blueman-applet"
        "mako"
        "hypridle"
        "wl-paste --watch cliphist store"
      ];
      windowrule = [
"float,polkit-kde-authentication-agent-1"
"center,polkit-kde-authentication-agent-1"
"size 500 500,polkit-kde-authentication-agent-1"
      ];
      env = [
        "XDG_SCREENSHOTS_DIR,$home/Pictures/Screenshots/"
        "XDG_PICTURES_DIR,$home/Pictures/"
        "GDK_BACKEND,wayland,x11,*"
        "QT_QPA_PLATFORM,wayland;xcb"
        "SDL_VIDEODRIVER,wayland"
        "CLUTTER_BACKEND,wayland"
        "HYPRCURSOR_THEME,rose-pine-hyprcursor"
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "XDG_SESSION_DESKTOP,Hyprland"
        "QT_AUTO_SCREEN_SCALE_FACTOR,1"
        "XCURSOR_SIZE,20"
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1"
      ];
      plugin = {
        hyprsplit = {
          num_workspaces = 10;
        };
      };
      input = {
        kb_layout = "us";
        follow_mouse = 1;
        touchpad = {
          clickfinger_behavior = true;
        };
        kb_options = "caps:swapescape";
      };
      general = {
        gaps_in = 3;
        gaps_out = 3;
      };
      decoration = {
        rounding = 0;
        active_opacity = 0.97;
        inactive_opacity = 0.9;
        blurls = [ "rofi" "wofi" ];
      };
      gestures = {
        workspace_swipe = true;
        workspace_swipe_fingers = 3;
        workspace_swipe_use_r = true;
        workspace_swipe_invert = false;
      };
      dwindle = {
        preserve_split = true;
        force_split = 0;
        smart_split = true;
      };
      binds = {
        allow_workspace_cycles = true;
        movefocus_cycles_fullscreen = false;
      };
      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        vrr = 2;
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
        middle_click_paste = false;
        focus_on_activate = true;
        force_default_wallpaper = 0;
      };


    };
  };
}
