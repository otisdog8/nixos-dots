# Kernel configuration - packages, parameters, modules, firmware
{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    
    initrd = {
      systemd.enable = true;
      verbose = false;
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        "usb_storage"
        "sd_mod"
      ];
      kernelModules = [ ];
    };

    # Quiet boot
    consoleLogLevel = 0;
    kernelParams = [
      "quiet"
      "splash"
      "loglevel=3"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
    ];

    # Kernel sysctl settings
    kernel.sysctl = {
      "fs.suid_dumpable" = 0;
      "vm.swappiness" = 10;
    };
  };

  # Firmware
  hardware = {
    enableAllFirmware = true;
    firmware = [
      pkgs.linux-firmware
      pkgs.sof-firmware
      pkgs.alsa-firmware
    ];
  };
}
