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
    enable = false;
    role = "controller+worker";
    spec.network.provider = "custom";
  };
}
