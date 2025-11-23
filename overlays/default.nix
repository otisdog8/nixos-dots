{ inputs, ... }:
{
  otisdog8-packages = final: _prev: {
    otisdog8 = import inputs.nixpkgs-otisdog8 {
      system = final.system;
      config.allowUnfree = true;
    };
  };
  older-packages = final: _prev: {
    older = import inputs.nixpkgs-older {
      system = final.system;
      config.allowUnfree = true;
    };
  };
  sandboxed-packages = import ./sandboxed-packages.nix { inherit inputs; };
  custom-packages = import ./custom-packages.nix { inherit inputs; };
}
