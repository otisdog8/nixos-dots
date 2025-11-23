{ inputs, ... }:
final: prev: {
  tetrio-desktop = final.callPackage ../pkgs/tetrio-desktop { };
}