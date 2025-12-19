# SDDM display manager configuration
{
  config,
  lib,
  pkgs,
  username,
  inputs,
  ...
}:
let
  cfg = config.modules.desktop.full.sddm;

  # Customizable theme settings
  astronautConfig = {
    wallpaper = "${inputs.self}/images/wallpaper.jpg";
    userIcon = "${inputs.self}/images/face.png";
    themeConfig = "pixel_sakura_static";

    colors = {
      textColor = "#ffffff";
      placeholderTextColor = "#cccccc";
      inputTextColor = "#ffffff";
      inputBackgroundColor = "#2a2a2a";
      iconColor = "#ffffff";
      buttonTextColor = "#ffffff";
      systemButtonsColor = "#ffffff";
    };
  };

  # Custom SDDM astronaut theme package
  customAstronautTheme = pkgs.stdenv.mkDerivation rec {
    pname = "sddm-astronaut-custom";
    version = "1.0";

    src = pkgs.sddm-astronaut;

    nativeBuildInputs = with pkgs; [
      makeBinaryWrapper
    ];

    installPhase = ''
            mkdir -p $out/share/sddm/themes/sddm-astronaut-custom
            cp -r $src/share/sddm/themes/sddm-astronaut-theme/* $out/share/sddm/themes/sddm-astronaut-custom/
            chmod -R u+w $out/share/sddm/themes/sddm-astronaut-custom

            # Replace the wallpaper
            rm -rf $out/share/sddm/themes/sddm-astronaut-custom/Backgrounds
            mkdir -p $out/share/sddm/themes/sddm-astronaut-custom/Backgrounds
            ln -s ${astronautConfig.wallpaper} $out/share/sddm/themes/sddm-astronaut-custom/Backgrounds/wallpaper.jpg

            # Set the theme configuration
            cat > $out/share/sddm/themes/sddm-astronaut-custom/metadata.desktop << EOF
      [SddmGreeterTheme]
      Name=Astronaut Custom
      Description=Custom Astronaut Theme with Pixel Sakura Static config
      Author=Keyitdev (customized)
      License=GPL-3.0-or-later
      Type=sddm-theme
      Version=1.3
      Website=https://github.com/keyitdev/sddm-astronaut-theme
      Screenshot=Previews/astronaut.png
      MainScript=Main.qml
      ConfigFile=Themes/${astronautConfig.themeConfig}.conf
      TranslationsDirectory=translations
      Theme-Id=sddm-astronaut-custom
      Theme-API=2.0
      QtVersion=6
      EOF

            # Customize the configuration file
            if [ -f "$out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf" ]; then
              sed -i "s|Background=.*|Background=\"Backgrounds/wallpaper.jpg\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf

              # Apply custom text colors
              sed -i "s|HeaderTextColor=.*|HeaderTextColor=\"${astronautConfig.colors.textColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|DateTextColor=.*|DateTextColor=\"${astronautConfig.colors.textColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|TimeTextColor=.*|TimeTextColor=\"${astronautConfig.colors.textColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|LoginFieldTextColor=.*|LoginFieldTextColor=\"${astronautConfig.colors.inputTextColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|PasswordFieldTextColor=.*|PasswordFieldTextColor=\"${astronautConfig.colors.inputTextColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|LoginFieldBackgroundColor=.*|LoginFieldBackgroundColor=\"${astronautConfig.colors.inputBackgroundColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|PasswordFieldBackgroundColor=.*|PasswordFieldBackgroundColor=\"${astronautConfig.colors.inputBackgroundColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|PlaceholderTextColor=.*|PlaceholderTextColor=\"${astronautConfig.colors.placeholderTextColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|UserIconColor=.*|UserIconColor=\"${astronautConfig.colors.iconColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|PasswordIconColor=.*|PasswordIconColor=\"${astronautConfig.colors.iconColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|SystemButtonsIconsColor=.*|SystemButtonsIconsColor=\"${astronautConfig.colors.systemButtonsColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|SessionButtonTextColor=.*|SessionButtonTextColor=\"${astronautConfig.colors.buttonTextColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|VirtualKeyboardButtonTextColor=.*|VirtualKeyboardButtonTextColor=\"${astronautConfig.colors.buttonTextColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|WarningColor=.*|WarningColor=\"${astronautConfig.colors.textColor}\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|HoverUserIconColor=.*|HoverUserIconColor=\"#dddddd\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|HoverPasswordIconColor=.*|HoverPasswordIconColor=\"#dddddd\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|HoverSystemButtonsIconsColor=.*|HoverSystemButtonsIconsColor=\"#dddddd\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|HoverSessionButtonTextColor=.*|HoverSessionButtonTextColor=\"#dddddd\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
              sed -i "s|HoverVirtualKeyboardButtonTextColor=.*|HoverVirtualKeyboardButtonTextColor=\"#dddddd\"|" \
                $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
            fi
    '';
  };
in
{
  options.modules.desktop.full.sddm = {
    enable = lib.mkEnableOption "SDDM display manager";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      customAstronautTheme
    ];

    system.activationScripts.copyIcon = ''
      mkdir -p /var/lib/AccountsService/icons
      cp ${astronautConfig.userIcon} /var/lib/AccountsService/icons/${username}
      chmod 755 /var/lib/AccountsService
      chmod 755 /var/lib/AccountsService/icons
      chmod 644 /var/lib/AccountsService/icons/${username}
    '';

    # Use Qt6 SDDM
    services.displayManager.sddm = {
      package = pkgs.kdePackages.sddm;
      wayland.enable = true;
      enable = true;
      theme = "sddm-astronaut-custom";

      extraPackages = with pkgs; [
        customAstronautTheme
        qt6.qtsvg
        qt6.qtmultimedia
        qt6.qt5compat
        kdePackages.qtvirtualkeyboard
      ];

      settings = {
        Theme = {
          Current = "sddm-astronaut-custom";
          ThemeDir = "/run/current-system/sw/share/sddm/themes";
        };
      };
    };

    services.displayManager.defaultSession = "hyprland";
  };
}
