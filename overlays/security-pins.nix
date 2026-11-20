# Security fixes nixos-unstable doesn't have yet, each pinned only while
# nixpkgs is older than the fix: once nixpkgs reaches the fixed version, it's
# nixpkgs' own package again (`fixedIn` below), so a flake update never goes
# back. Delete an entry once nixpkgs has it.
#
#   - nginx 1.30.7 / 1.31.9: NGINX2Root (CVE-2026-123007 and four more,
#     2026-11-18), unauthenticated RCE in HTTP/2 (on by default for SSL
#     vhosts), HTTP/3, the resolver and the mail proxy. recusant's nginx.
#   - Linux 7.3.5 / 6.18.64: KVM (CVE-2026-99312, 2026-11).
#
# Not pinned (for now): OpenJDK 17.0.21.1 / 21.0.13.1 / 25.0.5.1, Java4Shell
# (CVE-2026-114938). Overriding openjdk* rebuilds everything that uses a JDK
# at build time, chromium and electron included, and the vulnerable JVMs run
# in the VMs. Upstream's tags, if they're wanted back (generic.nix takes its
# source from nixpkgs-openjdk-updater's openjdkSource):
#   jdk17u jdk-17.0.21.1+2 sha256-b7bPdI2QDIN/199mKEIHkOeL3uAMCZ7PECnUYiBQmqY=
#   jdk21u jdk-21.0.13.1+2 sha256-FnUmoKUEztFXRIrzGRRccFlVkR3iB9Liv54HLOgoawM=
#   jdk25u jdk-25.0.5.1+2  sha256-PBBWftxwDL7TZGN/EXIPEVPZJbQ+/hjgXHmDDAzIJH0=
final: prev:
let
  inherit (final) lib;
  aliases = prev.linuxKernel.packageAliases;

  fixedIn =
    pkg: version: pinned:
    if lib.versionAtLeast pkg.version version then pkg else pinned;

  nginx =
    pkg: version: hash:
    fixedIn pkg version (
      pkg.overrideAttrs (_: {
        inherit version;
        nginxVersion = version;
        src = final.fetchurl {
          url = "https://nginx.org/download/nginx-${version}.tar.gz";
          inherit hash;
        };
      })
    );

  kernel =
    pkg: version: hash:
    fixedIn pkg version (
      pkg.override {
        argsOverride = {
          inherit version;
          modDirVersion = lib.versions.pad 3 version;
          src = final.fetchurl {
            url = "mirror://kernel/linux/kernel/v${lib.versions.major version}.x/linux-${version}.tar.xz";
            inherit hash;
          };
        };
      }
    );

  linux_7_3 = kernel prev.linux_7_3 "7.3.5" "sha256:1409kzrpxs9baxffajhbaczdfygawk2ynqv8wndpn2sgsn1kyacg";
  linux_6_18 = kernel prev.linux_6_18 "6.18.64" "sha256:0qp5mnx2wkqk14z2n27vavpvglvqd1b72p2cy7k756ak1i8la382";
in
{
  nginxStable = nginx prev.nginxStable "1.30.7" "sha256-JWW1yDcFDpWPcPsPc8SOK8pFQq00n9NW9G+wxyYQvG4=";
  nginxMainline = nginx prev.nginxMainline "1.31.9" "sha256-oRxe7uLiV/RHjw5kn4SwBAeH0nfS0+UjOVKqa23LgK0=";

  inherit linux_7_3 linux_6_18;
  linuxPackages_7_3 = final.linuxPackagesFor linux_7_3;
  linuxPackages_6_18 = final.linuxPackagesFor linux_6_18;
  # The aliases follow only while they still name those branches (nixpkgs'
  # own aliases: pkgs.linux_latest is final's, through the one below).
  linuxPackages_latest =
    if aliases.linux_latest.kernel.version == prev.linux_7_3.version then
      final.linuxPackages_7_3
    else
      prev.linuxPackages_latest;
  linuxPackages =
    if aliases.linux_default.kernel.version == prev.linux_6_18.version then
      final.linuxPackages_6_18
    else
      prev.linuxPackages;
}
