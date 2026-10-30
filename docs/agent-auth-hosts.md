# agent-auth on a host: commands (hostd) and the agent VM (sandboxd)

How to bring a host under agent-auth, written for the k3s nodes (arquitens,
carrack, munificent) and valid for any host in this flake. The nodes get
hostd only (commands and shells as jrt and as root) and no agent VM:
sections 1 to 5. Section 6 is for the hosts that have the VM. Design:
agent-auth's `docs/sandbox-design.md`. Modules here:
`nixos/modules/system/agent-auth-daemons.nix` (both daemons),
`nixos/modules/system/agent-vm.nix` (the VM).

What exists after it:

- **hostd** runs approved commands on the host: as jrt (user tier), as root
  (root tier), and time-boxed shells where enabled. Every command is approved
  at the broker, and the host then decides for itself from its own config, its
  TOTP secrets and whether the tier is armed.
- **The agent VM** runs headless claude/codex agents, one unix user per
  project, under **sandboxd** in the guest. Its orchestrator is the agent
  `orchestrator-<host>-sandbox`.

State as of 2026-10-12: excelsior and recusant are paired and run commands;
excelsior's VM runs agents. The k3s nodes' config has both tiers and shells
in both and has not been rebuilt with them (before that they ran hostd
unprivileged, connecting only); the broker lists none of them as a host, so
expect to pair each. galaxy has the VM and both tiers in its config and has
not been rebuilt with them. Not confirmed on hardware anywhere: recusant's
VM, a VM on a k3s node, galaxy's GPU in its VM.

## What it means on a k3s node

- Root on a node is the cluster: the kubelet's credentials, and etcd on the
  servers. A root command there is a larger grant than any Kubernetes role
  the broker hands out. Root stays a human's decision per command (the broker
  forces it, and the host accepts no machine approval). Root shells are on
  for the nodes (`root.shells`): each is opened by a human with that node's
  own root TOTP code, lasts two hours at most, and shows every command on
  Discord before it runs. While one is open, the agent holding it is root on
  the node.
- No agent VM on the nodes. Were one wanted later: the VM's RAM is the host's: `memory` MiB plus 512, committed as the guest
  touches it, and the kubelet doesn't know about it. Size it so that
  `VM + kubelet's allocatable` fits, or lower the node's allocatable by the
  same amount (k3s `--kubelet-arg=system-reserved=memory=…`). Disk: a sparse
  image at `/large/agent-vm/disk.img` (all three nodes have `/large`), 256G
  nominal.
- The VM reaches the internet, the broker (svc:sensitive), attic on recusant, the homelab
  gateways and the nodes' 6443/443/80, and nothing else of the LAN or the
  tailnet (`modules.agentVm.network` in `nixos/default.nix`). On a node that
  includes the node's own API server, like any other client's.
- Lockdown (`/lockdown`) freezes the VM from outside and kills hostd's jobs.
  It does nothing to k3s.

## 1. Config

In `nixos/hosts/<host>/default.nix`:

```nix
modules.agentAuth.hostCommands = {
  user.enable = true;   # commands as jrt
  root.enable = true;   # commands as root: always approved by a human
  user.shells = true;   # shells as jrt, each opened with a TOTP code
  root.shells = true;   # root shells, the same with a root code
};

# Only for a host that gets the VM (not the nodes):
modules.agentVm = {
  enable = true;
  memory = 8192;   # MiB; the default is 16384
  vcpus = 4;       # the default is 8
};
```

The three nodes have the first block already. They evaluate with it, and
with the VM's block too (no failed assertion). The rest
comes from the modules: hostd as root with the VM's unit to freeze, the
broker's pinned key, sandboxd and the claude/codex packages in the guest,
`/var/lib/agent-auth-hostd` persisted, vsock loaded, user namespaces left on
(crosvm's jails need them; the `k3s-node` hardening profile keeps them).

The `nixos-dots-push`, `nixos-dots-pull` and `nixos-dots-rebuild` templates
come with any tier. They act on the host's own checkout
(`modules.agentAuth.hostCommands.checkout`, default
`/persist/home/jrt/Documents/nixos-dots`), which must be unlocked with
git-crypt to build. None of them runs the checkout's hooks or a command its
git config names (sandboxes can write `.git/`): push goes to
`hostCommands.pushRemote`, pull fetches from `hostCommands.remote`, and the
rebuild builds the approved commit from the checkout's objects in a fresh
root-owned copy, never the work tree. A host without a checkout simply has
templates that fail; keeping a checkout (and the git-crypt key) on a node is
a choice, not a requirement: the node can be rebuilt from a workstation
instead.

## 2. Deploy

Rebuild the host the way it is normally rebuilt. One node at a time, and
check the cluster between nodes: the switch restarts hostd and nothing of
k3s, but it is still a system switch on a storage node. The VM is never
restarted by a rebuild; a changed guest takes effect at `agent-vm restart`.

## 3. Pair hostd

The broker's side needs the admin token (the broker's `ADMIN_TOKEN`, in
homelab-sensitive's `agent-auth-env` Secret) and the admin door:
`AGENT_AUTH_URL=https://broker-admin.s.rooty.dev` (the agent door,
broker.s.rooty.dev, refuses `/admin`). The code is typed at a prompt, never
passed as an argument.

```sh
# where the admin token is:
agent-auth admin daemon-pair <host>        # prints a one-time code (10 min)

# on the host:
sudo agent-auth-hostd pair                 # asks for the code; compare the fingerprints
```

Skip this where the host is already paired (`agent-auth admin daemons`, or
`/hosts` on Discord). Enabling a tier makes hostd run as root with the same
state directory, so the pairing should carry over; if the host shows offline
after the rebuild, pair it again (that replaces the key).

## 4. Enrol TOTP

```sh
sudo agent-auth-hostd totp-enroll          # four QR codes, each shown once
```

`user-arm`, `user-direct`, `root-arm`, `root-direct`, generated on the host.
Name them by host in the authenticator: every host has its own four. Nothing
runs on the host before this.

A shell (`host_shell`) opens with its tier's arm code, never a direct one, or
with Allow at the host's own desk and the password (polkit). Optional
secrets, each with `sudo agent-auth-hostd totp-enroll --add <name>`:
`user-shell` / `root-shell` (a shell code of its own instead of the arm
code) and `root-unlock` (remote unlock after a lockdown; without it, unlock
at the host).

## 5. Check hostd

```sh
agent-auth admin daemons                   # the host, online, its version
sudo agent-auth-hostctl status             # on the host: tiers, armed or not
journalctl -u agent-auth-hostd -n 30
```

Then, from any agent, a harmless command as the user tier (for example
`host_run` of `["uname", "-a"]` on the host): approve it on Discord with a
`user-direct` code, or arm the tier first (`/arm <host> user 1h <user-arm
code>`) and press Approve.

## 6. The VM and sandboxd

```sh
agent-vm status                            # agent-vm and agent-vm-net active
ls -l /dev/kvm /dev/vhost-vsock            # both present
agent-vm ssh                               # root in the guest, over vsock
```

First start formats the disk image. If the VM does not start, the unit that
failed says why: `journalctl -u agent-vm -u agent-vm-prep -u agent-vm-net`.

Pair the guest's daemon:

```sh
# where the admin token is:
agent-auth admin daemon-pair --role sandbox <host>

# on the host:
avm pair
```

That creates `orchestrator-<host>-sandbox` at the broker. Give the runtimes
their logins (subscription OAuth; read from stdin, never an argument), make a
project and open a conversation:

```sh
avm secret-set claude-oauth-token < FILE
avm project-create <project>
avm claude <project>                       # mints claude-<project>-<host>-sandbox on first use
avm ls
```

The mint is approved by policy (`agents`/`mint` for a VM's orchestrator in
homelab-sensitive's `infra/agent-auth/app/policy.yaml`); everything the new agent then asks for
goes through the same rules as any agent's, by its recorded fields
(`placement: sandbox`, its project).

## 7. Policy

Nothing per host is needed in the broker's policy. Worth doing when a host
gets a VM whose projects should have "their own" repo and namespace rules:
list the project under `projects:` in
homelab-sensitive's `infra/agent-auth/app/policy.yaml`.

## Undo

- A tier: remove it from the host's config and rebuild; the broker refuses
  requests for a tier a host reports off.
- The host: `agent-auth admin daemon-unpair <id>`; its agents' grants end
  with `agent-auth admin agent-disable orchestrator-<host>-sandbox` (that
  disables everything it minted too).
- The VM: `modules.agentVm.enable = false`, rebuild, then remove
  `/large/agent-vm` if the projects in it are not wanted.

## galaxy's GPU

`modules.agentVm.gpu.enable` gives the VM the host's NVIDIA GPU for compute
through virtio-nvgpu (the backend the app VMs use), with no display. After
the rebuild and `agent-vm restart`:

```sh
systemctl status agent-vm-gpu agent-vm-gpu-open agent-vm
agent-vm exec nvidia-smi                   # the card, as the guest sees it
journalctl -u agent-vm-gpu -n 30           # the backend's start-up lines
```

The backend refuses to start on a host driver release it has no tables for
(galaxy's 595.104.02 is one it has). Which card, how much video memory, and
the window size are `modules.agentVm.gpu.{devices,vramLimitMiB,windowMiB}`;
galaxy's choice and the alternative are in its `default.nix`.
