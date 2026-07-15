# Hyprland window manager codfiguration
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.full.hyprland;
  system = pkgs.stdenv.hostPlatform.system;

  # Screencopy permission allow-list targets. Exact store paths double as
  # regexes for hl.permission — they re-interpolate on every rebuild.
  portalExe = "${
    inputs.hyprland.packages.${system}.xdg-desktop-portal-hyprland
  }/libexec/xdg-desktop-portal-hyprland";
  grimExe = lib.getExe pkgs.grim;
  hyprlockExe = lib.getExe pkgs.hyprlock;
  hyprpickerExe = lib.getExe pkgs.hyprpicker;

  # hyprsplit is now a Lua library (the C++ plugin is deprecated on `legacy`).
  # The `hyprsplitlua` output just ships init.lua; we symlink + require it.
  hyprsplitInit = "${inputs.hyprsplit.packages.${system}.hyprsplitlua}/share/hyprsplit/init.lua";

  # Binds, env, autostart and the hyprsplit require live in one readable Lua
  # file. Dispatchers are Lua calls (hl.dsp.*), so they cannot go through the
  # home-manager settings->lua converter without mkLuaInline noise; raw Lua
  # here keeps them legible and lets us reuse Lua loops for the repetitive binds.
  hyprlandLua = ''
    local hs = require("hyprsplit")
    hs.config({ num_workspaces = 10 })

    local mod = "SUPER"
    local home = os.getenv("HOME")

    -----------------------------------------------------------------
    -- Environment
    -----------------------------------------------------------------
    hl.env("XDG_SCREENSHOTS_DIR", home .. "/Pictures/Screenshots/")
    hl.env("XDG_PICTURES_DIR", home .. "/Pictures/")
    hl.env("GDK_BACKEND", "wayland,x11,*")
    hl.env("QT_QPA_PLATFORM", "wayland;xcb")
    hl.env("SDL_VIDEODRIVER", "wayland")
    hl.env("CLUTTER_BACKEND", "wayland")
    hl.env("HYPRCURSOR_THEME", "rose-pine-hyprcursor")
    hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
    hl.env("XDG_SESSION_TYPE", "wayland")
    hl.env("XDG_SESSION_DESKTOP", "Hyprland")
    hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
    hl.env("XCURSOR_SIZE", "20")
    hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")

    -----------------------------------------------------------------
    -- Autostart
    -----------------------------------------------------------------
    hl.on("hyprland.start", function()
      hl.exec_cmd("kwalletd6")
      hl.exec_cmd("systemctl --user start hyprpolkitagent")
      hl.exec_cmd("polkit-agent-helper-1")
      hl.exec_cmd("${pkgs.kdePackages.kwallet-pam}/libexec/pam_kwallet_init")
      hl.exec_cmd("waybar")
      hl.exec_cmd("nm-applet")
      hl.exec_cmd("blueman-applet")
      hl.exec_cmd("mako")
      hl.exec_cmd("wl-paste --watch cliphist store")
    end)

    -----------------------------------------------------------------
    -- Keybindings
    -----------------------------------------------------------------
    hl.bind(mod .. " + V", hl.dsp.exec_cmd("cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"))
    hl.bind(mod .. " + n", hl.dsp.exec_cmd("nix-search-fuzzel"))
    hl.bind(mod .. " + SHIFT + n", hl.dsp.exec_cmd("nix-search-clipboard"))
    hl.bind("CTRL + ALT + l", hl.dsp.exec_cmd("loginctl lock-session"))
    hl.bind("CTRL + ALT + t", hl.dsp.exec_cmd("kitty"))
    hl.bind("CTRL + Space", hl.dsp.exec_cmd("rofi -show drun"))
    hl.bind("CTRL + SHIFT + q", hl.dsp.exec_cmd("wlogout -b 2 -c 0 -r 0 -m 0 --protocol layer-shell"))
    hl.bind("ALT + tab", hl.dsp.window.cycle_next())
    hl.bind("ALT + F4", hl.dsp.window.close())
    hl.bind("ALT + SHIFT + F4", hl.dsp.exec_cmd("hyprctl kill"))
    hl.bind(mod .. " + q", hl.dsp.exec_cmd("kitty"))
    hl.bind(mod .. " + m", hl.dsp.window.fullscreen())
    -- exec_raw is exec-without-sh (execr), not a dispatcher passthrough, so the
    -- old `exec_raw("fullscreenstate -1 2")` spawned a nonexistent program.
    -- action = "toggle" dispatches unconditionally like hyprlang fullscreenstate.
    hl.bind(mod .. " + SHIFT + m", hl.dsp.window.fullscreen_state({ internal = -1, client = 2, action = "toggle" }))
    hl.bind(mod .. " + p", hl.dsp.window.pseudo())
    hl.bind(mod .. " + s", hl.dsp.window.float({ action = "toggle" }))
    hl.bind(mod .. " + d", hs.dsp.workspace.swap_monitors({ monitor1 = "current", monitor2 = "+1" }))
    hl.bind(mod .. " + g", hs.dsp.grab_rogue_windows())
    hl.bind(mod .. " + SHIFT + g", hl.dsp.exec_cmd("hyprshade toggle grayscale"))
    hl.bind(mod .. " + SHIFT + b", hl.dsp.exec_cmd("hyprshade toggle blue-light-filter"))
    hl.bind(mod .. " + r", hl.dsp.layout("togglesplit"))
    hl.bind(mod .. " + w", hl.dsp.exec_cmd("killall -SIGUSR1 waybar"))
    hl.bind("CTRL + SHIFT + Space", hl.dsp.exec_cmd("grimblast --freeze copysave area"))
    hl.bind("XF86PowerOff", hl.dsp.exec_cmd("wlogout -b 2 -c 0 -r 0 -m 0 --protocol layer-shell"))
    hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl s +5%"))
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl s 5%-"))
    hl.bind("XF86AudioStop", hl.dsp.exec_cmd("playerctl stop"))
    hl.bind("XF86AudioMedia", hl.dsp.exec_cmd("playerctl play-pause"))
    hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"))
    hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"))
    hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"))
    hl.bind("SHIFT + XF86AudioNext", hl.dsp.exec_cmd("playerctl previous"))
    hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))

    -- Volume (repeat while held)
    hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true })
    hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%-"), { repeating = true })

    -- Mouse move/resize
    hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

    -- Lid switch: lock + conditionally suspend on battery
    hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd(
      "loginctl lock-session && touch /tmp/10midle && test $(cat /sys/class/power_supply/AC0/online) = 0 && sleep 1 && systemctl suspend"
    ), { locked = true })

    -- Workspaces 1..10 (per-monitor via hyprsplit)
    for i = 1, 10 do
      local key = i % 10 -- 10 maps to key 0
      hl.bind(mod .. " + " .. key, hs.dsp.focus({ workspace = i }))
      hl.bind(mod .. " + SHIFT + " .. key, hs.dsp.window.move({ workspace = i, follow = false }))
    end

    -- Directional focus/move/resize/workspace, on both arrow keys and vim keys
    local dirs = {
      { key = "left",  vim = "h", dir = "left",  rx = -20, ry = 0,   ws = "r-1" },
      { key = "right", vim = "l", dir = "right", rx = 20,  ry = 0,   ws = "r+1" },
      { key = "up",    vim = "k", dir = "up",    rx = 0,   ry = -20, ws = "emptynm" },
      { key = "down",  vim = "j", dir = "down",  rx = 0,   ry = 20,  ws = "previous_per_monitor" },
    }
    for _, x in ipairs(dirs) do
      for _, k in ipairs({ x.key, x.vim }) do
        hl.bind(mod .. " + " .. k, hl.dsp.focus({ direction = x.dir }))
        hl.bind(mod .. " + SHIFT + " .. k, hl.dsp.window.move({ direction = x.dir }))
        hl.bind(mod .. " + CTRL + " .. k, hl.dsp.window.resize({ x = x.rx, y = x.ry, relative = true }))
        hl.bind(mod .. " + ALT + " .. k, hl.dsp.focus({ workspace = x.ws }))
        hl.bind(mod .. " + ALT + SHIFT + " .. k, hl.dsp.window.move({ workspace = x.ws }))
      end
    end
  '';
in
{
  imports = [
    ./waybar
    ./hyprlock.nix
    ./hypridle.nix
    ./hyprpaper.nix
    ./wlogout.nix
  ];

  options.modules.desktop.full.hyprland = {
    enable = lib.mkEnableOption "Hyprland window manager";
  };

  config = lib.mkIf cfg.enable {
    # System-level Hyprland configuration
    programs.hyprland = {
      enable = true;
      package = inputs.hyprland.packages."${pkgs.stdenv.hostPlatform.system}".hyprland;
      portalPackage =
        inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    };

    # Desktop packages
    environment.systemPackages = with pkgs; [
      grim
      slurp
      hyprpicker
      hyprland-qtutils # renders the permission (ask) dialogs
      cliphist
      libnotify
      grimblast
      wl-clipboard
      wofi
      tofi
      rofi
      fuzzel
      brightnessctl
      hyprpolkitagent
      mako
      hyprshade
      psmisc
      inputs.hyprland.packages."${pkgs.stdenv.hostPlatform.system}".hyprland
      xdg-desktop-portal-hyprland
      networkmanager-openvpn
      networkmanagerapplet
      kdePackages.networkmanager-qt
      gparted
    ];

    # XDG desktop portal symlinks
    systemd.tmpfiles.rules = [
      "L+ /usr/share/xdg-desktop-portal/portals - - - - /run/current-system/sw/share/xdg-desktop-portal/portals "
      "L+ /usr/libexec/xdg-desktop-portal-gtk - - - - ${pkgs.xdg-desktop-portal-gtk}/libexec/xdg-desktop-portal-gtk "
      "L+ /usr/libexec/xdg-desktop-portal-hyprland - - - - ${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland "
      "L+ /usr/libexec/xdg-desktop-portal - - - - ${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal "
    ];

    # Enable child modules
    modules.desktop.full.hyprland = {
      waybar.enable = lib.mkDefault true;
      hyprlock.enable = lib.mkDefault true;
      hypridle.enable = lib.mkDefault true;
      hyprpaper.enable = lib.mkDefault true;
      wlogout.enable = lib.mkDefault true;
    };

    # Home-manager Hyprland configuration
    home-manager.users.${username} = {
      imports = [
        inputs.hyprland.homeManagerModules.default
      ];

      # Hyprshade shaders
      xdg.configFile."hypr/shaders/grayscale.glsl".source = ./shaders/grayscale.glsl;

      wayland.windowManager.hyprland = {
        enable = true;
        # Lua config (hyprlang is deprecated since 0.55). Required to use the
        # permission system, which is Lua-only and read once at startup.
        configType = "lua";
        package = inputs.hyprland.packages.${system}.hyprland;
        portalPackage = inputs.hyprland.packages.${system}.xdg-desktop-portal-hyprland;
        systemd.variables = [ "--all" ];

        # Table-shaped keywords stay declarative: home-manager renders each as
        # hl.<name>(<lua table>). Call-shaped keywords (bind/env/exec) live in
        # extraLuaFiles below as raw Lua to avoid mkLuaInline everywhere.
        settings = {
          config = {
            # Permission system on. Rules below are enforced from startup;
            # changes need a full Hyprland restart, not `hyprctl reload`.
            ecosystem = {
              enforce_permissions = true;
            };
            debug = {
              disable_logs = false;
            };
            animations = {
              enabled = false;
            };
            gestures = {
              workspace_swipe_invert = false;
            };
            input = {
              kb_layout = "us";
              follow_mouse = 1;
              kb_options = "caps:escape";
              touchpad = {
                clickfinger_behavior = true;
              };
            };
            general = {
              gaps_in = 3;
              gaps_out = 3;
            };
            decoration = {
              rounding = 0;
              active_opacity = 0.97;
              inactive_opacity = 0.9;
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

          monitor = [
            {
              output = "";
              mode = "highres";
              position = "auto";
              scale = 1;
              bitdepth = 8;
            }
          ];

          gesture = [
            {
              fingers = 3;
              direction = "horizontal";
              action = "workspace";
            }
          ];

          # Permission rules (first match wins, so catch-alls come last).
          # screencopy default is `ask`; allow the portal (consented sharing)
          # and grim (screenshots), prompt for anything else. cursorpos prompts.
          # keyboard default is `allow`; allow the internal keyboard and prompt
          # for any other keyboard (blocks silent virtual-kbd injection without
          # a hard lockout). Add device names from `hyprctl devices` per host.
          permission = [
            {
              binary = portalExe;
              type = "screencopy";
              mode = "allow";
            }
            {
              binary = grimExe;
              type = "screencopy";
              mode = "allow";
            }
            {
              binary = hyprlockExe;
              type = "screencopy";
              mode = "allow";
            }
            {
              binary = hyprpickerExe;
              type = "screencopy";
              mode = "allow";
            }
            {
              binary = ".*";
              type = "screencopy";
              mode = "ask";
            }
            {
              binary = ".*";
              type = "cursorpos";
              mode = "ask";
            }
            {
              binary = ".*";
              type = "keyboard";
              mode = "allow";
            }
          ];
        };

        # hyprsplit (Lua library) + the call-shaped config, in raw Lua.
        extraLuaFiles = {
          # Symlink the library so `require("hyprsplit")` resolves; not
          # auto-run — hyprlandLua requires it explicitly.
          "hyprsplit/init" = {
            autoLoad = false;
            content = builtins.readFile hyprsplitInit;
          };
          "hm-hyprland" = {
            autoLoad = true;
            content = hyprlandLua;
          };
        };
      };
    };

    # Persistence for hyprland
    environment.persistence."/persist" = {
      users.${username} = {
        directories = [
          ".cache/cliphist"
        ];
      };
    };
  };
}
