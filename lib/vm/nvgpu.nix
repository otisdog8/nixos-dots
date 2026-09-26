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
#               guest's Wayland clients.
#   - crosvm:   crosvm at the revision the fork's patch series targets, with the
#               series applied (`--vhost-user type=nvgpu`, backend-mapping
#               checks, `--no-pci-hotplug-port`).
#   - wlGuest:  nvgpu-wl-guest, the guest half of the proxy: serves the guest's
#               $XDG_RUNTIME_DIR/wayland-0 over /dev/nvgpu-wl.
#   - kmod:     the guest kernel module (virtio_gpu_nv), built against the
#               guest's kernel; it registers /dev/nvidia*, a DRM device and
#               /dev/nvgpu-wl in the guest.
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

  crosvmRev = "c0474109d64d9795e8855533b33486d2b62f14dd";
  patchDir = "${src}/patches/crosvm";
  crosvmPatches = map (n: "${patchDir}/${n}") (
    lib.sort lib.lessThan (
      lib.filter (n: lib.hasSuffix ".patch" n) (lib.attrNames (builtins.readDir patchDir))
    )
  );
in
{
  backend = mkCrate {
    pname = "vhost-user-nvgpu";
    crate = "device";
    bin = "vhost-user-nvgpu";
    features = [ "vhost-user" ];
  };

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
