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
      availableKernelModules = [
        "xhci_pci"
        "thunderbolt"
        "nvme"
        #"usb_storage"
        "sd_mod"
      ];
      kernelModules = [ ];
    };

    extraModprobeConfig = ''
      install esp4 /bin/false
      install esp6 /bin/false
      install rxrpc /bin/false
      install algif_aead /bin/false
    '';

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
      # SysRq from the keyboard: R (4: unraw, SAK), S (16: sync), U (32:
      # remount read-only), E/I/F (64: term, kill, OOM-kill) and B/O (128:
      # reboot, power off): REISUB plus O and F. Not log level (2), the
      # process/memory dumps (8) or nicing RT tasks (256). /proc/sysrq-trigger
      # stays root-only whatever this says.
      "kernel.sysrq" = 244;
      "dev.tty.legacy_tiocsti" = 0;
      # Raise inotify limits: large modpacks (PrismLauncher) open many config
      # file watchers and exhaust the defaults, crashing the game at startup.
      "fs.inotify.max_user_watches" = 1048576;
      "fs.inotify.max_user_instances" = 1024;
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
