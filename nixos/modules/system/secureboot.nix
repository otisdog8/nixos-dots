# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
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
  # TPM2 configuration
  security.tpm2 = {
    enable = true;
    pkcs11.enable = true; # expose /run/current-system/sw/lib/libtpm2_pkcs11.so
    tctiEnvironment.enable = true; # TPM2TOOLS_TCTI and TPM2_PKCS11_TCTI env variables
  };

  systemd.tpm2.enable = true;

  # Boot configuration
  # boot.kernelPackages = pkgs.linuxPackages_latest;
  boot = {
    initrd.systemd = {
      enable = true;
      tpm2.enable = true;
    };

    # Use the systemd-boot EFI boot loader.
    loader = {
      systemd-boot.enable = lib.mkForce false;
      efi.canTouchEfiVariables = true;
    };

    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };
  };
  environment.systemPackages = with pkgs; [
    sbctl
    tpm2-tss
  ];

  # Persistence for secureboot
  environment.persistence."/persist" = {
    directories = [
      "/etc/secureboot"
      "/var/lib/sbctl"
    ];
  };
}
