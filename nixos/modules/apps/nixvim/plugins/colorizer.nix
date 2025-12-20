# nvim-colorizer - Color highlighter for color codes
{ lib, ... }:
{
  plugins.colorizer = {
    enable = true;

    # Lazy load on buffer read
    lazyLoad.settings.event = [
      "BufReadPost"
      "BufNewFile"
    ];

    settings = {
      # Highlight all files, with specific customizations
      filetypes = {
        __unkeyed-1 = "*";
        css = {
          rgb_fn = true; # Enable parsing rgb(...) functions in css
        };
        html = {
          names = false; # Disable parsing "names" like Blue or Gray
        };
      };

      user_default_options = {
        RGB = true; # #RGB hex codes
        RRGGBB = true; # #RRGGBB hex codes
        names = true; # "Name" codes like Blue
        RRGGBBAA = true; # #RRGGBBAA hex codes
        AARRGGBB = true; # 0xAARRGGBB hex codes
        rgb_fn = true; # CSS rgb() and rgba() functions
        hsl_fn = true; # CSS hsl() and hsla() functions
        css = true; # Enable all CSS features: rgb_fn, hsl_fn, names, RGB, RRGGBB
        css_fn = true; # Enable all CSS *functions*: rgb_fn, hsl_fn
        tailwind = true; # Enable tailwind colors
        mode = "background"; # Set the display mode: 'foreground', 'background', 'virtualtext'
        always_update = true;
      };
    };
  };

  # Toggle keymap
  keymaps = [
    {
      mode = "n";
      key = "<leader>uC";
      action = "<cmd>ColorizerToggle<CR>";
      options.desc = "Toggle Colorizer";
    }
  ];
}
