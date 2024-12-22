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
  ];

  environment.systemPackages = with pkgs; [
    inputs.k0s.packages."${pkgs.system}".k0s
  ];

  services.k0s = {
    package = inputs.k0s.packages."${pkgs.system}".k0s;
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
