# Todo-comments - Highlight todo, notes, etc in comments
{ lib, ... }:
{
  plugins.todo-comments = {
    enable = true;
    lazyLoad.settings.event = "VimEnter";
    settings = {
      signs = false;
    };
  };
}
