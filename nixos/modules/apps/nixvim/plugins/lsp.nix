# LSP configuration
{ lib, ... }:
{
  plugins.lspconfig.enable = true;

  lsp = {
    inlayHints.enable = true;
    servers.nixd.enable = true;

    # LSP keymaps (set on LspAttach)
    keymaps = [
      {
        key = "grn";
        lspBufAction = "rename";
      }
      {
        key = "gra";
        lspBufAction = "code_action";
      }
      {
        key = "grD";
        lspBufAction = "declaration";
      }
    ];
  };

  # Additional LSP keybindings using nixvim keymaps
  keymaps = [
    # Snacks picker integrations for LSP
    {
      mode = "n";
      key = "grr";
      action.__raw = "function() Snacks.picker.lsp_references() end";
      options.desc = "LSP: [G]oto [R]eferences";
    }
    {
      mode = "n";
      key = "gri";
      action.__raw = "function() Snacks.picker.lsp_implementations() end";
      options.desc = "LSP: [G]oto [I]mplementation";
    }
    {
      mode = "n";
      key = "grd";
      action.__raw = "function() Snacks.picker.lsp_definitions() end";
      options.desc = "LSP: [G]oto [D]efinition";
    }
    {
      mode = "n";
      key = "gO";
      action.__raw = "function() Snacks.picker.lsp_symbols() end";
      options.desc = "LSP: Open Document Symbols";
    }
    {
      mode = "n";
      key = "gW";
      action.__raw = "function() Snacks.picker.lsp_workspace_symbols() end";
      options.desc = "LSP: Open Workspace Symbols";
    }
    {
      mode = "n";
      key = "grt";
      action.__raw = "function() Snacks.picker.lsp_type_definitions() end";
      options.desc = "LSP: [G]oto [T]ype Definition";
    }

    # Inlay hints toggle
    {
      mode = "n";
      key = "<leader>th";
      action.__raw = ''
        function()
          vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = 0 }))
        end
      '';
      options.desc = "LSP: [T]oggle Inlay [H]ints";
    }
  ];

  # Document highlight on cursor hold
  autoGroups.kickstart-lsp-highlight.clear = false;
  autoGroups.kickstart-lsp-detach.clear = true;

  autoCmd = [
    {
      event = "LspAttach";
      callback.__raw = ''
        function(event)
          local client = vim.lsp.get_client_by_id(event.data.client_id)
          
          -- Helper function for version compatibility
          local function client_supports_method(client, method, bufnr)
            if vim.fn.has('nvim-0.11') == 1 then
              return client:supports_method(method, bufnr)
            else
              return client.supports_method(method, { bufnr = bufnr })
            end
          end

          -- Document highlight on cursor hold
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_documentHighlight, event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds({ group = 'kickstart-lsp-highlight', buffer = event2.buf })
              end,
            })
          end
        end
      '';
    }
  ];

  # Diagnostic configuration
  extraConfigLua = ''
    vim.diagnostic.config({
      severity_sort = true,
      float = {
        border = "rounded",
        source = "if_many",
      },
      underline = {
        severity = vim.diagnostic.severity.ERROR,
      },
      signs = {
        text = {
          [vim.diagnostic.severity.ERROR] = '󰅚 ',
          [vim.diagnostic.severity.WARN] = '󰀪 ',
          [vim.diagnostic.severity.INFO] = '󰋽 ',
          [vim.diagnostic.severity.HINT] = '󰌶 ',
        },
      },
      virtual_text = {
        source = "if_many",
        spacing = 2,
      },
    })
  '';
}
