# Kernel configuration - packages, parameters, modules, firmware
{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.initrd.systemd.enable = true;

  # Quiet boot
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;
  boot.kernelParams = [
    "quiet"
    "splash"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_priority=3"
  ];

  # Kernel modules
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];

  # Kernel sysctl settings
  boot.kernel.sysctl = {
    "fs.suid_dumpable" = 0;
    "vm.swappiness" = 10;
  };

  # Firmware
  hardware.enableAllFirmware = true;
  hardware.firmware = [
    pkgs.linux-firmware
    pkgs.sof-firmware
    pkgs.alsa-firmware
  ];
}
