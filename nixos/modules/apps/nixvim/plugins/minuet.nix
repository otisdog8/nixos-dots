# AI-powered code completion
{ lib, ... }:
{
  plugins.minuet = {
    enable = true;
    
    settings = {
      # Provider configuration
      provider = "openai_compatible";
      
      # Performance settings
      request_timeout = 3;
      throttle = 1000;
      debounce = 400;
      
      # Context window - 16k characters ~ 4k tokens
      context_window = 16000;
      context_ratio = 0.75;
      
      # Number of completions to request
      n_completions = 3;
      add_single_line_entry = true;
      
      # Notification level
      notify = "warn";
      
      # Provider options for OpenRouter with Kimi
      provider_options = {
        openai_compatible = {
          api_key = "OPENROUTER_API_KEY";
          end_point = "https://openrouter.ai/api/v1/chat/completions";
          model = "moonshotai/kimi-k2-0905:exacto";
          name = "OpenRouter";
          stream = true;
          optional = {
            max_tokens = 128;
            top_p = 0.9;
            provider = {
              # Prioritize throughput for faster completion
              sort = "throughput";
            };
          };
        };
      };
    };
  };
  
  # Keymaps for manual completion toggle
  keymaps = [
    {
      mode = "n";
      key = "<leader>um";
      action = "<cmd>Minuet blink toggle<CR>";
      options.desc = "Toggle Minuet completion";
    }
  ];
}
