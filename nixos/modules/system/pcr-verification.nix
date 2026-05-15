# Post-unlock PCR 15 verification for TPM2 LUKS auto-unlock.
# Defense against filesystem-confusion attacks (oddlama, 2025-01-16).
# Per-host opt-in via modules.system.pcr-verification.enable.
#
# See modules/system/PCR-VERIFICATION.md for the operator runbook.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.system.pcr-verification;
in
{
  options.modules.system.pcr-verification = {
    enable = lib.mkEnableOption "PCR 15 verification for TPM2 LUKS unlock";

    expectedPcr15 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Expected SHA-256 hex of TPM PCR 15 after all LUKS volumes have been
        unlocked and their keys measured. Capture with
        `systemd-analyze pcrs 15 --json=short` on a known-good boot.
        When null, only measurement is enabled (no enforcement) - use this
        for the bootstrap boot, then fill in the captured value.
      '';
      #example = "caf33e79c645b65849256238a11fa68ae197e5cb89730c463c1cdf1d9128376f";
    };
  };

  config = lib.mkIf cfg.enable {
    # Every host in this repo names its LUKS device "luks" by convention.
    # We can't `mapAttrs` over `config.boot.initrd.luks.devices` here -
    # that's an infinite recursion (reading the attr we're writing). If
    # a host ever uses a different name, the assertion below will trip,
    # and the right fix is to either rename the device or generalize
    # this module via a submodule type extension.
    assertions = [
      {
        assertion = config.boot.initrd.luks.devices ? "luks";
        message = "modules.system.pcr-verification expects a LUKS device named \"luks\".";
      }
    ];
    boot.initrd = {
      luks.devices."luks".crypttabExtraOpts = [ "tpm2-measure-pcr=yes" ];

      systemd = {
        # Initrd-stage emergency shell uses the root password, so a PCR
        # mismatch (or any other initrd failure) lands at an
        # authenticated rescue prompt instead of an unbootable system.
        # Upstream default is `false` (no rescue access at all).
        emergencyAccess = config.users.users.root.hashedPassword;

        # jq is needed inside the initrd to parse `systemd-analyze pcrs`.
        storePaths = [ "${pkgs.jq}/bin/jq" ];

        services.check-pcr15 = lib.mkIf (cfg.expectedPcr15 != null) {
          description = "Verify TPM PCR 15 matches expected post-unlock value";
          wantedBy = [ "initrd.target" ];
          requiredBy = [ "sysroot.mount" ];
          after = [ "cryptsetup.target" ];
          # Run before the impermanence rollback so a mismatched boot never
          # touches the (potentially attacker-controlled) btrfs.
          before = [
            "sysroot.mount"
            "rollback.service"
          ];
          unitConfig.DefaultDependencies = "no";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            actual=$(${pkgs.systemd}/bin/systemd-analyze pcrs 15 --json=short \
                     | ${pkgs.jq}/bin/jq -r '.[0].sha256')
            if [[ "$actual" != "${cfg.expectedPcr15}" ]]; then
              echo "PCR 15 verification FAILED" >&2
              echo "  expected: ${cfg.expectedPcr15}" >&2
              echo "  actual:   $actual" >&2
              exit 1
            fi
            echo "PCR 15 verification OK ($actual)"
          '';
        };
      };
    };
  };
}
