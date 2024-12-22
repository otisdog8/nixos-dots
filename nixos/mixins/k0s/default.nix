{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  outputs,
  pkgs,
  platform,
  stateVersion,
  username,
  ...
}:

{
  imports = [
     inputs.k0s.nixosModules.default
     ({
        inputs.nixpkgs.pkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
          overlays = [
            inputs.k0s.overlays.default
          ];
        };
     })
  ];
  services.k0s = {
    enable = true;
    role = "controller+worker";
    spec.network.provider = "custom";
    spec.api.sans = [
      "100.126.30.73" # arquitens
      "100.103.225.29" # carrack
      "100.65.16.13" # munificent
    ];
  };
}
