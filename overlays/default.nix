{ inputs, ... }:
{
  otisdog8-packages = final: _prev: {
    otisdog8 = import inputs.nixpkgs-otisdog8 {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
  older-packages = final: _prev: {
    older = import inputs.nixpkgs-older {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };
  custom-packages = import ./custom-packages.nix { inherit inputs; };
}
