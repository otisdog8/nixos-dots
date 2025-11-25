{
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
let
  # Customizable theme settings
  astronautConfig = {
    # Path to your wallpaper
    wallpaper = "${inputs.self}/images/wallpaper.jpg";

    # User icon
    userIcon = "${inputs.self}/images/face.png";

    # Theme variant configuration file
    # Available options: astronaut, black_hole, cyberpunk, hyprland_kath,
    # jake_the_dog, japanese_aesthetic, pixel_sakura, pixel_sakura_static,
    # post-apocalyptic_hacker, purple_leaves
    themeConfig = "pixel_sakura_static";

    # Color customization
    colors = {
      # Text colors (main UI text)
      textColor = "#ffffff";           # White text for header, date, time
      placeholderTextColor = "#cccccc"; # Light gray for placeholders

      # Input field colors
      inputTextColor = "#ffffff";      # White text in input fields
      inputBackgroundColor = "#2a2a2a"; # Dark background for inputs

      # Button and icon colors
      iconColor = "#ffffff";           # White icons
      buttonTextColor = "#ffffff";     # White button text

      # System buttons
      systemButtonsColor = "#ffffff";  # White system buttons
    };
  };

  # Custom SDDM astronaut theme package with our configuration
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
        # Update background path
        sed -i "s|Background=.*|Background=\"Backgrounds/wallpaper.jpg\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf

        # Apply custom text colors - make text white
        sed -i "s|HeaderTextColor=.*|HeaderTextColor=\"${astronautConfig.colors.textColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
        sed -i "s|DateTextColor=.*|DateTextColor=\"${astronautConfig.colors.textColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
        sed -i "s|TimeTextColor=.*|TimeTextColor=\"${astronautConfig.colors.textColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf

        # Input field text colors
        sed -i "s|LoginFieldTextColor=.*|LoginFieldTextColor=\"${astronautConfig.colors.inputTextColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
        sed -i "s|PasswordFieldTextColor=.*|PasswordFieldTextColor=\"${astronautConfig.colors.inputTextColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
        sed -i "s|LoginFieldBackgroundColor=.*|LoginFieldBackgroundColor=\"${astronautConfig.colors.inputBackgroundColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf
        sed -i "s|PasswordFieldBackgroundColor=.*|PasswordFieldBackgroundColor=\"${astronautConfig.colors.inputBackgroundColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf

        # Placeholder text
        sed -i "s|PlaceholderTextColor=.*|PlaceholderTextColor=\"${astronautConfig.colors.placeholderTextColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf

        # Icon and button colors
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

        # Warning text
        sed -i "s|WarningColor=.*|WarningColor=\"${astronautConfig.colors.textColor}\"|" \
          $out/share/sddm/themes/sddm-astronaut-custom/Themes/${astronautConfig.themeConfig}.conf

        # Hover colors (lighter white)
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
  environment.systemPackages = with pkgs; [
    # Qt6 packages for general system use
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtimageformats
    qt6.qtwayland

    # Qt6 theming
    kdePackages.qtstyleplugin-kvantum

    # Icon themes and cursors
    candy-icons
    inputs.rose-pine-hyprcursor.packages.${pkgs.stdenv.hostPlatform.system}.default
    rose-pine-cursor

    # Custom SDDM theme (must be in systemPackages to be found by SDDM)
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

    # Add theme to extraPackages to ensure all dependencies are available
    extraPackages = with pkgs; [
      customAstronautTheme
      qt6.qtsvg
      qt6.qtmultimedia
      qt6.qt5compat
      kdePackages.qtvirtualkeyboard
    ];

    # Additional SDDM settings for better compatibility
    settings = {
      Theme = {
        Current = "sddm-astronaut-custom";
        ThemeDir = "/run/current-system/sw/share/sddm/themes";
      };
    };
  };

  services.displayManager.defaultSession = "hyprland";
}
