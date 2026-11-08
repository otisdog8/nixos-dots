# The kernel surface a bwrap sandbox (the nixpak backend, the systemd
# backend's inner sandbox, a group's shared container, a VM's nested one) can
# reach: nested user namespaces and a seccomp filter. Set per app through
# app.capabilities.nestedUserns and app.capabilities.seccomp (lib/app-spec.nix),
# lowered in lib/capabilities-nixpak.nix to this module's sbx.syscalls.
#
# Nested user namespaces (bwrap --disable-userns, our nixpak patch in
# nixpak-pkg.nix): a sandboxed process that makes its own user namespace gets
# every capability in it, and with that nf_tables (NETLINK_NETFILTER), xfrm,
# qdiscs and link types (NETLINK_ROUTE), AF_PACKET/AF_XDP, and mounting
# overlayfs/fuse: the code behind most local privilege escalations. bwrap puts
# the app in one more user namespace and sets its parent's
# user.max_user_namespaces to 1, so the app can't make another (unshare -U:
# ENOSPC). What genuinely nests namespaces opts in: Chromium/Electron/CEF/
# QtWebEngine (their zygote sandbox), Firefox/Zen (their content processes'
# sandbox), Steam (pressure-vessel is bwrap), and what runs other sandboxed
# apps (system-bin.nix: the agents, sandbox-shell). For those the seccomp
# filter below still applies inside the nested namespace, so it can't reach
# NETLINK_NETFILTER, XFRM, AF_PACKET/AF_XDP and the like; what remains is
# NETLINK_ROUTE with CAP_NET_ADMIN in its own network namespace (qdiscs,
# classifiers, link types), mounting (overlayfs, fuse) and the namespaced
# sysctls.
#
# The seccomp filter (built here with libseccomp, loaded by bwrap
# --add-seccomp-fd from a wrapper that is nixpak's bubblewrap.package, so it
# covers nixpak's xdg-dbus-proxy sandbox too; bwrap loads it last, right before
# exec'ing the app, and it is inherited by everything the app starts, nested
# sandboxes included). Default allow; denied:
#   - io_uring_setup/enter/register: ENOSYS, so libuv, tokio and the like fall
#     back to ordinary I/O (io_uring also does socket/open/connect as ring ops
#     that seccomp never sees)
#   - perf_event_open (opt in: seccomp.perf), userfaultfd, bpf,
#     add_key/keyctl/request_key (opt in: seccomp.keyrings, for 1Password),
#     modify_ldt (opt in: seccomp.modifyLdt, for Wine/Proton), ioctl
#     TIOCSTI/TIOCLINUX: EPERM
#   - any non-native ABI (i386 syscalls, int 0x80): the process is killed
#     (opt in: seccomp.i386, for 32-bit binaries: Steam)
#   - socket() and socketpair() families other than AF_UNIX, AF_INET,
#     AF_INET6 and AF_NETLINK (opt in more: seccomp.socketFamilies):
#     EAFNOSUPPORT. AF_VSOCK among them: from the host it reaches every VM's
#     guest services.
#   - netlink protocols other than NETLINK_ROUTE (addresses, routes: glibc's
#     getaddrinfo, Chromium's network-change notifier) and
#     NETLINK_KOBJECT_UEVENT (libudev's device monitor: gamepads, hotplug)
#     (opt in more: seccomp.netlinkProtocols): EPROTONOSUPPORT.
#   ptrace and process_vm_* stay allowed (Yama ptrace_scope 1 already limits
#   them to descendants; debuggers and crash reporters need them).
# With the i386 ABI allowed (Steam's filter, and so the whole games group's
# sandbox, which gets it), the socket family and netlink protocol limits apply
# to 64-bit code only: 32-bit code can still open AF_VSOCK, AF_PACKET,
# NETLINK_NETFILTER and the rest. Its socketcall()'s arguments are in memory,
# out of seccomp's reach, and libseccomp can't filter its direct socket()
# alone. The syscall denials above do cover it. The build loads each filter
# in a child and probes a few of its denials (the generator's selftest).
#
# Group sandboxes (nixpak-group.nix) import every member's settings into one
# sandbox, which gets the most permissive of them: the options below merge that
# way (the capabilities set only the permissive value, mkIf).
{ lib, pkgs }:
let
  inherit (pkgs.stdenv) hostPlatform;

  baseFamilies = [
    "AF_UNIX"
    "AF_INET"
    "AF_INET6"
    "AF_NETLINK"
  ];
  baseNetlink = [
    "NETLINK_ROUTE"
    "NETLINK_KOBJECT_UEVENT"
  ];
  # Names the C generator resolves through <sys/socket.h> / <linux/netlink.h>.
  familyNames = [
    "AF_AX25"
    "AF_IPX"
    "AF_APPLETALK"
    "AF_NETROM"
    "AF_BRIDGE"
    "AF_ATMPVC"
    "AF_X25"
    "AF_ROSE"
    "AF_DECnet"
    "AF_NETBEUI"
    "AF_SECURITY"
    "AF_KEY"
    "AF_PACKET"
    "AF_ASH"
    "AF_ECONET"
    "AF_ATMSVC"
    "AF_RDS"
    "AF_SNA"
    "AF_IRDA"
    "AF_PPPOX"
    "AF_WANPIPE"
    "AF_LLC"
    "AF_IB"
    "AF_MPLS"
    "AF_CAN"
    "AF_TIPC"
    "AF_BLUETOOTH"
    "AF_IUCV"
    "AF_RXRPC"
    "AF_ISDN"
    "AF_PHONET"
    "AF_IEEE802154"
    "AF_CAIF"
    "AF_ALG"
    "AF_NFC"
    "AF_VSOCK"
    "AF_KCM"
    "AF_QIPCRTR"
    "AF_SMC"
    "AF_XDP"
    "AF_MCTP"
  ]
  ++ baseFamilies;
  netlinkNames = [
    "NETLINK_USERSOCK"
    "NETLINK_FIREWALL"
    "NETLINK_SOCK_DIAG"
    "NETLINK_NFLOG"
    "NETLINK_XFRM"
    "NETLINK_SELINUX"
    "NETLINK_ISCSI"
    "NETLINK_AUDIT"
    "NETLINK_FIB_LOOKUP"
    "NETLINK_CONNECTOR"
    "NETLINK_NETFILTER"
    "NETLINK_IP6_FW"
    "NETLINK_DNRTMSG"
    "NETLINK_GENERIC"
    "NETLINK_SCSITRANSPORT"
    "NETLINK_ECRYPTFS"
    "NETLINK_RDMA"
    "NETLINK_CRYPTO"
    "NETLINK_SMC"
  ]
  ++ baseNetlink;

  x86 = hostPlatform.isx86_64;

  # The filter as BPF (what bwrap --add-seccomp-fd reads), one derivation per
  # set of opt-ins; its `pfc` output is libseccomp's readable form of it.
  filter =
    {
      i386 ? false,
      modifyLdt ? false,
      perf ? false,
      keyrings ? false,
      socketFamilies ? [ ],
      netlinkProtocols ? [ ],
    }:
    let
      families = lib.unique (baseFamilies ++ socketFamilies);
      netlink = lib.unique (baseNetlink ++ netlinkProtocols);
      cList = lib.concatStringsSep ", ";
      tag = lib.concatMapStrings (t: "-" + t) (
        lib.optional i386 "i386"
        ++ lib.optional modifyLdt "ldt"
        ++ lib.optional perf "perf"
        ++ lib.optional keyrings "keyrings"
        ++ lib.optional (socketFamilies != [ ] || netlinkProtocols != [ ]) (
          builtins.substring 0 8 (
            builtins.hashString "sha256" (
              toString (lib.sort lib.lessThan families ++ lib.sort lib.lessThan netlink)
            )
          )
        )
      );
      src = pkgs.writeText "sbx-seccomp.c" ''
        #include <errno.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <fcntl.h>
        #include <sys/ioctl.h>
        #include <sys/socket.h>
        #include <sys/syscall.h>
        #include <sys/wait.h>
        #include <linux/netlink.h>
        #include <seccomp.h>

        /* One context per ABI, merged at the end, each rule added exactly.
           socket()/socketpair() rules go to the native one only: on i386,
           libseccomp turns them into rules on socketcall(SYS_SOCKET) too,
           whose arguments are in memory, so they'd deny every family to
           32-bit code using socketcall (glibc does), and it can't add them to
           the direct syscall alone. */
        static scmp_filter_ctx ctxs[2];
        static uint32_t arches[2];
        static int nctx;

        static void rule(int action, const char *name, unsigned n, struct scmp_arg_cmp *a)
        {
          int native_only = !strcmp(name, "socket") || !strcmp(name, "socketpair");
          for (int i = 0; i < (native_only ? 1 : nctx); i++) {
            /* libseccomp takes the native number and translates it. */
            int nr = seccomp_syscall_resolve_name(name);
            if (nr == __NR_SCMP_ERROR) {
              fprintf(stderr, "unknown syscall %s\n", name);
              exit(1);
            }
            int r = seccomp_rule_add_exact_array(ctxs[i], action, nr, n, a);
            if (r) {
              fprintf(stderr, "rule on %s (arch %u): %s\n", name, arches[i], strerror(-r));
              exit(1);
            }
          }
        }

        static scmp_filter_ctx context(uint32_t arch)
        {
          scmp_filter_ctx c = seccomp_init(SCMP_ACT_ALLOW);
          /* A syscall of an ABI the filter doesn't have (i386 without
             seccomp.i386, x32): kill the process; returning ENOSYS would
             leave a 32-bit program running on with every syscall failing,
             exit included. */
          if (!c || seccomp_attr_set(c, SCMP_FLTATR_ACT_BADARCH, SCMP_ACT_KILL_PROCESS))
            exit(1);
          if (arch != SCMP_ARCH_NATIVE) {
            if (seccomp_arch_remove(c, SCMP_ARCH_NATIVE) || seccomp_arch_add(c, arch))
              exit(1);
          } else {
            arch = seccomp_arch_native();
          }
          ctxs[nctx] = c;
          arches[nctx++] = arch;
          return c;
        }
        #define DENY(e, name) rule(SCMP_ACT_ERRNO(e), name, 0, NULL)
        #define LOW32 0xffffffffULL

        static int cmp_int(const void *a, const void *b)
        {
          return *(const int *)a - *(const int *)b;
        }

        /* Deny `sys` (socket or socketpair) for every value of argument
           `arg` (with AF_NETLINK in a0 when `netlink`) not in `allowed`: each
           one below the highest allowed one by its low 32 bits (the kernel
           reads an int), and everything above it as a 64-bit value (which
           also catches set upper bits). */
        static void deny_except(const char *sys, int arg, int netlink, int err, int *allowed, size_t n)
        {
          qsort(allowed, n, sizeof *allowed, cmp_int);
          int top = allowed[n - 1];
          for (int v = 0; v <= top; v++) {
            int ok = 0;
            for (size_t i = 0; i < n; i++)
              ok |= allowed[i] == v;
            if (ok)
              continue;
            struct scmp_arg_cmp a[2] = {
              { arg, SCMP_CMP_MASKED_EQ, LOW32, (scmp_datum_t)v },
              { 0, SCMP_CMP_MASKED_EQ, LOW32, AF_NETLINK },
            };
            rule(SCMP_ACT_ERRNO(err), sys, netlink ? 2 : 1, a);
          }
          struct scmp_arg_cmp a[2] = {
            { arg, SCMP_CMP_GE, (scmp_datum_t)top + 1, 0 },
            { 0, SCMP_CMP_MASKED_EQ, LOW32, AF_NETLINK },
          };
          rule(SCMP_ACT_ERRNO(err), sys, netlink ? 2 : 1, a);
        }

        /* The build's check: load the filter (in a child) and probe it. */
        static int expect(const char *what, long r, int err)
        {
          int got = r < 0 ? errno : 0;
          if (got != err) {
            fprintf(stderr, "selftest: %s: got %s, want %s\n", what,
                    got ? strerror(got) : "success", err ? strerror(err) : "success");
            return 1;
          }
          if (r >= 0 && strncmp(what, "socket", 6) == 0)
            close((int)r);
          return 0;
        }

        static int selftest(scmp_filter_ctx ctx)
        {
          pid_t pid = fork();
          if (pid < 0)
            return 1;
          if (pid == 0) {
            if (seccomp_load(ctx))
              _exit(2);
            int bad = 0;
            bad |= expect("io_uring_setup", syscall(SCMP_SYS(io_uring_setup), 1, NULL), ENOSYS);
            ${
              if keyrings then
                "bad |= syscall(SCMP_SYS(keyctl), 0, -3, 0) < 0 && errno == EPERM;"
              else
                ''bad |= expect("keyctl", syscall(SCMP_SYS(keyctl), 0, -3, 0), EPERM);''
            }
            bad |= expect("userfaultfd", syscall(SCMP_SYS(userfaultfd), 0), EPERM);
            bad |= expect("ioctl TIOCSTI", ioctl(0, (unsigned long)TIOCSTI | (1UL << 32), "x"), EPERM);
            bad |= expect("socket AF_UNIX", socket(AF_UNIX, SOCK_STREAM, 0), 0);
            bad |= expect("socket AF_VSOCK", socket(40 /* AF_VSOCK */, SOCK_STREAM, 0), EAFNOSUPPORT);
            bad |= expect("socket AF_PACKET", syscall(SCMP_SYS(socket), AF_PACKET | (1L << 32), SOCK_RAW, 0), EAFNOSUPPORT);
            bad |= expect("socket NETLINK_ROUTE", socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE), 0);
            bad |= expect("socket NETLINK_NETFILTER", socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER), EPROTONOSUPPORT);
            int sv[2];
            bad |= expect("socketpair AF_UNIX", socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);
            bad |= expect("socketpair AF_VSOCK", socketpair(40, SOCK_STREAM, 0, sv), EAFNOSUPPORT);
            _exit(bad);
          }
          int st;
          if (waitpid(pid, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st)) {
            fprintf(stderr, "selftest failed (status %d)\n", st);
            return 1;
          }
          return 0;
        }

        int main(int argc, char **argv)
        {
          context(SCMP_ARCH_NATIVE);
          ${lib.optionalString (i386 && x86) "context(SCMP_ARCH_X86);"}

          DENY(ENOSYS, "io_uring_setup");
          DENY(ENOSYS, "io_uring_enter");
          DENY(ENOSYS, "io_uring_register");
          ${lib.optionalString (!perf) ''DENY(EPERM, "perf_event_open");''}
          DENY(EPERM, "userfaultfd");
          DENY(EPERM, "bpf");
          ${lib.optionalString (!keyrings) ''
            DENY(EPERM, "add_key");
            DENY(EPERM, "keyctl");
            DENY(EPERM, "request_key");
          ''}
          ${lib.optionalString (!modifyLdt && x86) ''DENY(EPERM, "modify_ldt");''}

          /* Typing into the terminal the sandbox shares (and the VT's
             selection/paste); the ioctl's cmd is an unsigned int. */
          {
            struct scmp_arg_cmp a = { 1, SCMP_CMP_MASKED_EQ, LOW32, TIOCSTI };
            rule(SCMP_ACT_ERRNO(EPERM), "ioctl", 1, &a);
            struct scmp_arg_cmp b = { 1, SCMP_CMP_MASKED_EQ, LOW32, TIOCLINUX };
            rule(SCMP_ACT_ERRNO(EPERM), "ioctl", 1, &b);
          }

          {
            int f[] = { ${cList families} };
            deny_except("socket", 0, 0, EAFNOSUPPORT, f, sizeof f / sizeof *f);
            deny_except("socketpair", 0, 0, EAFNOSUPPORT, f, sizeof f / sizeof *f);
            int p[] = { ${cList netlink} };
            deny_except("socket", 2, 1, EPROTONOSUPPORT, p, sizeof p / sizeof *p);
          }

          scmp_filter_ctx ctx = ctxs[0];
          for (int i = 1; i < nctx; i++)
            if (seccomp_merge(ctx, ctxs[i]))
              return 1;
          if (argc > 1 && !strcmp(argv[1], "pfc"))
            return seccomp_export_pfc(ctx, 1) ? 1 : 0;
          if (argc > 1 && !strcmp(argv[1], "test"))
            return selftest(ctx);
          return seccomp_export_bpf(ctx, 1) ? 1 : 0;
        }
      '';
    in
    pkgs.runCommandCC "sbx-seccomp${tag}"
      {
        buildInputs = [ pkgs.libseccomp ];
        outputs = [
          "out"
          "pfc"
        ];
      }
      ''
        $CC -O2 -Wall -Werror -o gen ${src} -lseccomp
        ./gen > $out
        ./gen pfc > $pfc
        ./gen test
      '';

  # bwrap with the filter loaded: nixpak's bubblewrap.package (its app sandbox
  # and its xdg-dbus-proxy sandbox both run it). bwrap reads the fd and closes
  # it, so the app doesn't inherit it.
  wrapper =
    bpf:
    pkgs.writeShellScriptBin "bwrap" ''
      exec 87<${bpf}
      exec ${pkgs.bubblewrap}/bin/bwrap --add-seccomp-fd 87 "$@"
    '';

  # The nixpak module: sbx.syscalls, lowered to bubblewrap.disableUserns (our
  # nixpak patch) and bubblewrap.package. Keyed, so a group sandbox importing
  # every member's module evaluates it once.
  module =
    { config, lib, ... }:
    let
      cfg = config.sbx.syscalls;
      opt =
        default: description:
        lib.mkOption {
          type = lib.types.bool;
          inherit default description;
        };
    in
    {
      key = "sbx-syscalls";
      options.sbx.syscalls = {
        nestedUserns = opt false "Let the sandbox make nested user namespaces (no bwrap --disable-userns).";
        seccomp = {
          enable = opt true "Load the sandbox's seccomp filter (lib/backends/bwrap-syscalls.nix).";
          i386 = opt false "Allow the i386 syscall ABI (32-bit binaries).";
          modifyLdt = opt false "Allow modify_ldt (Wine/Proton).";
          perf = opt false "Allow perf_event_open.";
          keyrings = opt false "Allow the kernel keyring syscalls (add_key, keyctl, request_key).";
          socketFamilies = lib.mkOption {
            type = lib.types.listOf (lib.types.enum familyNames);
            default = [ ];
            description = "socket() families allowed besides AF_UNIX, AF_INET, AF_INET6, AF_NETLINK.";
          };
          netlinkProtocols = lib.mkOption {
            type = lib.types.listOf (lib.types.enum netlinkNames);
            default = [ ];
            description = "Netlink protocols allowed besides NETLINK_ROUTE and NETLINK_KOBJECT_UEVENT.";
          };
        };
      };
      config = {
        bubblewrap.disableUserns = !cfg.nestedUserns;
        bubblewrap.package = lib.mkIf cfg.seccomp.enable (
          wrapper (filter {
            inherit (cfg.seccomp)
              i386
              modifyLdt
              perf
              keyrings
              socketFamilies
              netlinkProtocols
              ;
          })
        );
      };
    };
in
{
  inherit
    filter
    wrapper
    module
    familyNames
    netlinkNames
    ;
}
