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
        #"usb_storage"
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
      # Audio codec power saving
      "snd_hda_intel.power_save=1"
      "snd_hda_intel.power_save_controller=Y"
      # NVMe power management for better s2idle
      "nvme.noacpi=1"
      # Intel Xe GPU power management
      "xe.enable_dc=4"
      "xe.enable_fbc=1"
      "xe.enable_psr=2"
      "xe.disable_power_well=1"
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
