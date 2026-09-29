# GPU + Wayland display for the VM sandbox tier, built from virtio-nvgpu
# (flake input `virtio-nvgpu`, the user's fork).
#
# virtio-nvgpu forwards the NVIDIA driver's interface to the host driver, and its
# backend doubles as the host half of a Wayland proxy: guest applications are
# clients of the host compositor, their GPU buffers are host GPU objects (no
# copy), and wl_shm buffers are copied per commit. The pieces:
#   - backend:  vhost-user-nvgpu, a host process per VM (its own sandbox:
#               network namespace, Landlock, seccomp) that crosvm talks to over
#               vhost-user, and that connects to the host compositor for the
#               guest's Wayland clients. `backendFor` builds a variant with a
#               VM's own window size and per-process share (below).
#   - crosvm:   crosvm at the revision the fork's patch series targets, with the
#               series applied (`--vhost-user type=nvgpu`, backend-mapping
#               checks, `--no-pci-hotplug-port`).
#   - wlGuest:  nvgpu-wl-guest, the guest half of the proxy: serves the guest's
#               $XDG_RUNTIME_DIR/wayland-0 over /dev/nvgpu-wl.
#   - kmod:     the guest kernel module (virtio_gpu_nv), built against the
#               guest's kernel; it registers /dev/nvidia*, a DRM device and
#               /dev/nvgpu-wl in the guest. Two fixes of ours are applied
#               (lib/vm/patches/nvgpu-*.patch), until the fork has them.
# Everything nixos-dots changes in the fork is listed, with why, for its
# maintainers in docs/virtio-nvgpu-gpu-window-and-compat-brief.md.
# The guest also needs NVIDIA's userspace at exactly the host driver's release
# (lib/vm/guest.nix takes the host's own hardware.nvidia.package).
{
  lib,
  pkgs,
  src,
}:
let
  version = "0-unstable-${src.shortRev or "local"}";

  # Both Rust binaries come from one workspace; each derivation builds its own
  # crate. Every dependency is on crates.io, so the lock file is enough.
  mkCrate =
    {
      pname,
      crate,
      bin,
      features ? [ ],
    }:
    pkgs.rustPlatform.buildRustPackage {
      inherit pname version src;
      cargoLock.lockFile = "${src}/Cargo.lock";
      cargoBuildFlags = [
        "-p"
        crate
        "--bin"
        bin
      ];
      buildFeatures = features;
      # The workspace's tests need a GPU, a guest, or a fake kernel harness.
      doCheck = false;
      meta.mainProgram = bin;
    };

  backend = mkCrate {
    pname = "vhost-user-nvgpu";
    crate = "device";
    bin = "vhost-user-nvgpu";
    features = [ "vhost-user" ];
  };

  crosvmRev = "c0474109d64d9795e8855533b33486d2b62f14dd";
  patchDir = "${src}/patches/crosvm";
  crosvmPatches = map (n: "${patchDir}/${n}") (
    lib.sort lib.lessThan (
      lib.filter (n: lib.hasSuffix ".patch" n) (lib.attrNames (builtins.readDir patchDir))
    )
  );
in
{
  inherit backend;

  # The backend with a VM's own shared-window size and per-process share
  # (sandbox.vm.gpuMemoryMiB / gpuMemoryProcessPercent; the fork's defaults,
  # 1024 and 50, are `backend` itself). The fork has no flag for either yet: the
  # window is ZoneConfig::default_1gib() (UC 32, WC 768, WB 224 MiB) and every
  # zone's share Share::half (half per process, the last eighth reserved for
  # processes holding at most a sixteenth). Until it has
  # (docs/virtio-nvgpu-gpu-window-and-compat-brief.md), a variant is built:
  #   - ZoneConfig::configured_window(): default_1gib()'s split, scaled;
  #   - ShmAllocator::set_owner_percent(): each zone's share at `ownerPercent`,
  #     the reserve shrunk to what that share leaves, the floor at most it;
  #   - NvidiaBackend::with_configured_window(): both, for the binary's one
  #     backend and its GET_SHMEM_CONFIG answer, so the window the VMM
  #     publishes is the one the allocator places in.
  # The new code is appended to the fork's modules (no anchor there to lose);
  # the binary's two call sites are replaced with --replace-fail, so a fork that
  # moves them fails the build. The build then runs this variant's own tests and
  # the fork's GET_SHMEM_CONFIG test: the window's size, the share admitted in
  # full and not a page more, a small process still served from the reserve.
  # What stays unchecked: a NEW call site the fork adds for the default window.
  backendFor =
    { windowMiB, ownerPercent }:
    assert lib.assertMsg (
      windowMiB >= 1024 && windowMiB <= 16384 && lib.mod windowMiB 1024 == 0
    ) "virtio-nvgpu: the GPU window must be 1024-16384 MiB in whole GiB, not ${toString windowMiB}";
    assert lib.assertMsg (
      ownerPercent >= 1 && ownerPercent <= 95
    ) "virtio-nvgpu: the per-process share must be 1-95%, not ${toString ownerPercent}";
    if windowMiB == 1024 && ownerPercent == 50 then
      backend
    else
      let
        scale = toString (windowMiB / 1024);
        mib = toString windowMiB;
        pct = toString ownerPercent;
      in
      backend.overrideAttrs (old: {
        pname = "vhost-user-nvgpu-w${mib}-p${pct}";
        postPatch = (old.postPatch or "") + ''
          substituteInPlace device/bin/vhost-user-nvgpu.rs \
            --replace-fail 'device::shm::ZoneConfig::default_1gib().total()' \
                           'device::shm::ZoneConfig::configured_window().total()' \
            --replace-fail 'let mut nvidia = NvidiaBackend::with_default_zones();' \
                           'let mut nvidia = NvidiaBackend::with_configured_window();' \
            --replace-fail 'assert_eq!(sizes[1], 1 << 30);' 'assert_eq!(sizes[1], ${mib} << 20);'

          cat >> device/src/shm.rs <<'EOF'

          // nixos-dots (lib/vm/nvgpu.nix `backendFor`): a ${mib} MiB window, ${pct}% per process.
          impl ZoneConfig {
              /// default_1gib()'s measured split, scaled to the configured window.
              pub fn configured_window() -> Self {
                  let d = Self::default_1gib();
                  assert_eq!(d.total(), 1 << 30, "default_1gib() is no longer 1 GiB");
                  Self {
                      uc_size: d.uc_size * ${scale},
                      wc_size: d.wc_size * ${scale},
                      wb_size: d.wb_size * ${scale},
                  }
              }
          }

          impl ShmAllocator {
              /// Each zone's per-process share at `percent` of the zone, page-aligned.
              /// The reserve is the smaller of Share::half's eighth and what the share
              /// leaves, so the share can be reached; the floor is at most the reserve.
              pub fn set_owner_percent(&mut self, percent: u64) {
                  assert!((1..=95).contains(&percent));
                  for zone in [&mut self.uc, &mut self.wc, &mut self.wb] {
                      assert_eq!(zone.free_bytes(), zone.size, "set before any allocation");
                      let per_owner = (zone.size * percent / 100) & !(PAGE_SIZE - 1);
                      let reserve = (zone.size / 8).min(zone.size - per_owner);
                      zone.share = Share {
                          per_owner,
                          reserve,
                          floor: (zone.size / 16).min(reserve),
                      };
                  }
              }
          }

          #[cfg(test)]
          mod nixos_dots_window {
              use super::*;

              #[test]
              fn nixos_dots_window_is_the_configured_size() {
                  let c = ZoneConfig::configured_window();
                  assert_eq!(c.total(), ${mib} << 20);
                  for s in [c.uc_size, c.wc_size, c.wb_size] {
                      assert!(s > 0 && s % PAGE_SIZE == 0);
                  }
              }
          }
          EOF

          cat >> device/src/nvidia.rs <<'EOF'

          // nixos-dots (lib/vm/nvgpu.nix `backendFor`).
          impl NvidiaBackend {
              /// The backend vhost-user-nvgpu serves with: the configured window and share.
              pub fn with_configured_window() -> Self {
                  let mut be = Self::new(ZoneConfig::configured_window());
                  be.shm.set_owner_percent(${pct});
                  be
              }
          }

          #[cfg(test)]
          mod nixos_dots_window {
              use super::*;
              use crate::quota::Owner;
              use crate::shm::PgprotKind::{WriteBack, WriteCombine};

              #[test]
              fn nixos_dots_share_is_enforced() {
                  let mut be = NvidiaBackend::with_configured_window();
                  assert_eq!(be.shm_total_size(), ${mib} << 20);
                  let cfg = ZoneConfig::configured_window();
                  let game = Owner::Proc { tgid: 1, start_ns: 1 };
                  let other = Owner::Proc { tgid: 2, start_ns: 2 };
                  for (kind, size) in [(WriteCombine, cfg.wc_size), (WriteBack, cfg.wb_size)] {
                      let share = (size * ${pct} / 100) & !4095;
                      be.shm.alloc_for(share, kind, game).expect("the whole share");
                      assert!(be.shm.alloc_for(4096, kind, game).is_err(), "past the share");
                      be.shm.alloc_for(4096, kind, other).expect("another process");
                  }
              }
          }
          EOF
        '';
        # The workspace's other tests need a GPU, a guest or a harness: only these.
        # Debug: cargo test rebuilds for unwinding anyway (release aborts on panic).
        doCheck = true;
        cargoCheckType = "debug";
        cargoTestFlags = [
          "-p"
          "device"
          "--lib"
          "--bin"
          "vhost-user-nvgpu"
        ];
        checkFlags = [
          "nixos_dots"
          "shmem_config"
        ];
      });

  wlGuest = mkCrate {
    pname = "nvgpu-wl-guest";
    crate = "nvgpu-wl-guest";
    bin = "nvgpu-wl-guest";
  };

  # The series is against this exact upstream revision (patches/README.md); it
  # doesn't apply to the older nixpkgs pin.
  crosvm = pkgs.crosvm.overrideAttrs (
    finalAttrs: old: {
      version = "0-unstable-2026-09-25-nvgpu";
      src = pkgs.fetchgit {
        url = "https://chromium.googlesource.com/chromiumos/platform/crosvm";
        rev = crosvmRev;
        hash = "sha256-nPlEgVNlL0bZ/ybfy0Eo+eTFiCKeH8aoEWtxW9QBosE=";
        fetchSubmodules = true;
      };
      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        inherit (finalAttrs) src;
        name = "crosvm-${finalAttrs.version}";
        hash = "sha256-5pcN+/pHOVHoEqDrYoNBkwSmv5b9+vdJMn7nnrXp0LM=";
      };
      patches = (old.patches or [ ]) ++ crosvmPatches;
    }
  );

  # Built with the kernel's own Kbuild (driver/Makefile doubles as the Kbuild file),
  # not the Makefile's `module` wrapper, whose sub-make chokes on the kernel
  # package's generic make flags.
  kmod =
    kernelPackages:
    let
      kernel = kernelPackages.kernel;
    in
    pkgs.stdenv.mkDerivation {
      pname = "virtio-gpu-nv";
      version = "${version}-${kernel.version}";
      src = "${src}/driver";
      patches = [
        # SYNCOBJ_HANDLE_TO_FD / FD_TO_HANDLE from headers older than the
        # timeline `point` (16 bytes, not 24; the Steam runtime's libdrm):
        # accepted as the DRM core accepts them, zero-extended, and forwarded as
        # the current ioctl. Before: EINVAL.
        ./patches/nvgpu-syncobj-legacy-handle.patch
        # 32-bit RM clients (Steam, 32-bit games) on /dev/nvidiactl and
        # /dev/nvidiaN: compat_ptr_ioctl, as nvidia.ko takes its native handler
        # for compat (RM's structs are fixed-width, pointers NvP64). The DRM
        # node already had this; without it every 32-bit ioctl was ENOTTY.
        ./patches/nvgpu-rm-compat-ioctl.patch
      ];
      nativeBuildInputs = kernel.moduleBuildDependencies;
      makeFlags = kernelPackages.kernelModuleMakeFlags ++ [
        "-C"
        "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
        "M=$(PWD)"
        "CONFIG_VIRTIO_GPU_NV=m"
        "NVGPU_RUST=0"
      ];
      buildFlags = [ "modules" ];
      installPhase = ''
        runHook preInstall
        install -Dm444 virtio_gpu_nv.ko \
          $out/lib/modules/${kernel.modDirVersion}/extra/virtio_gpu_nv.ko
        runHook postInstall
      '';
    };
}
