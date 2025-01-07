{ inputs, ... }:
{
  otisdog8-packages = final: _prev: {
    otisdog8 = import inputs.nixpkgs-otisdog8 {
      system = final.system;
      config.allowUnfree = true;
    };
  };
}
