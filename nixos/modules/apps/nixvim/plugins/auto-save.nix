# Auto-save on text changes
{ lib, ... }:
{
  plugins.auto-save = {
    enable = true;
    lazyLoad.settings.event = [
      "InsertLeave"
      "TextChanged"
    ];

    settings = {
      enabled = true;
      debounce_delay = 1000;
      write_all_buffers = false;

      # Don't save special buffers
      condition = lib.nixvim.mkRaw ''
        function(buf)
          local fn = vim.fn
          local utils = require("auto-save.utils.data")
          
          -- Ignore special filetypes
          if utils.not_in(fn.getbufvar(buf, "&filetype"), {
            "oil",
            "checkhealth",
          }) then
            return true
          end
          return false
        end
      '';
    };
  };
}
