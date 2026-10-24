# Cluster nodes as VMs

Each k3s machine (arquitens, carrack, munificent) becomes a hypervisor,
`<machine>-hv`, that runs its k3s node as a VM and nothing else
(`modules/system/node-vm.nix`). Later it runs a second VM beside it, the
sensitive cluster's node. Root in a node is then root in its VM, not on the
machine: one cluster's node is no way into the other's (each VM's crosvm
runs as a uid of its own, `node-vm-<name>`, that owns only that VM's control
socket, macvtap and disks). That holds only while
the machine stays out of reach. It has no agent-auth hostd, no k3s, no libvirt
and no agent VM, and only jrt can ssh in.

The node keeps being the node: the same hostname, etcd member, Tailscale
address, Rook OSD and mon, and local PVs. Its state was always on disks of
its own (XFS `/data`, the SATA Ceph SSD), and the VM gets those disks whole.
What made the machine *that node* (ssh host keys, Tailscale state, machine-id,
hostd's pairing, the Ceph LUKS key, the LAN MAC and so its DHCP lease) moves
into the VM. The machine starts over as `<machine>-hv`.

| | machine (`hosts/<node>-hv`) | node VM (`hosts/<node>-node`, hostname `<node>`) |
|---|---|---|
| boots | Secure Boot, TPM-unlocked LUKS, as before | directly: kernel, initrd, `init=` from the machine's store |
| store | its own | the machine's, read-only over virtio-fs |
| disks | NVMe: ESP, LUKS → vg: `pool`, `swap` | `vg/node` (32G btrfs: root, persist, large, cache, dots), `vg/node-swap`, `vg/data`, the SATA SSD |
| LAN | dongle with a new MAC (`02:` in place of `00:`), new lease | macvtap with the dongle's MAC, so the node's address |
| memory | ~4 GiB | 46 GiB, and up to ~2 GiB of crosvm's own (room for the sensitive VM: ~8 GiB) |

| node | node's LAN (the dongle's MAC) | Tailscale | machine | machine's LAN | converted |
|---|---|---|---|---|---|
| arquitens | 10.0.0.10, 00:24:27:88:a9:c4 | 100.126.30.73 | arquitens-hv | 10.0.0.4, 02:24:27:88:a9:c4 | 2026-10-17 |
| carrack | 10.0.0.11, 00:24:27:88:a9:bc | 100.103.225.29 | carrack-hv | 10.0.0.5, 02:24:27:88:a9:bc | 2026-10-18 |
| munificent | 10.0.0.12, 00:24:27:88:a9:cd | 100.65.16.13 | munificent-hv | 10.0.0.6, 02:24:27:88:a9:cd | |

Deploying a node from now on means rebuilding `<node>-hv`, which builds the
guest and pins it. A rebuild alone never restarts it. Then the node rolls
itself onto that system: `sudo node-rollout <system>` on the node
(modules/system/k3s/rollout.nix) switches live when the kernel is the same,
and otherwise drains, sets noout and reboots itself into the machine's pin,
one node at a time. `--reboot` forces the drained reboot; `--bounce` reboots
without draining or health checks. From any checkout, `nix run .#rollout --
nodes` does all of it: the three machines, then each node in turn
(pkgs/rollout). `sudo node-vm restart node` on the machine is the hard way:
no drain, no lock.

## Converting a machine

Below, `<node>` is the node's name (carrack, say) and the machine becomes
`<node>-hv`. In a shell, `n=carrack` once, then `$n` wherever `<node>` is.

**Do one machine per sitting.** While a machine is converting, etcd runs on
two members and Ceph on two OSDs. A second failure in that window stops
writes. Have fresh backups, and wait for `HEALTH_OK` and three healthy etcd
members before starting the next machine. Converting the last of the three
leaves no node with a GPU: see immich below.

### Before (nothing stops)

1. Push the commits, and build `.#<node>-hv` (it builds the guest too).
   Check the machine is what `hosts/<node>-hv` assumes: `nproc` at least 16
   (the VM takes 14), `free -g` about 62 total, `ip -br link` shows the
   dongle as `enp4s0f4u1`, and `sudo vgs vg` has at least 48G free (for `node` and `node-swap`), and `sudo lvs vg` lists `data`, which the VM gets. `sudo lvs vg`
   may still list the interim `ceph` LV; nothing uses it, and it can stay.
   From a converted node, `tailscale ping <node>` should say `via
   10.0.0.x:41641`: a direct path through the macvtap, not DERP.
   Cilium must not depend on this node's API server alone: `kubectl -n
   kube-system get ds/cilium deploy/cilium-operator -o yaml | grep -A1
   KUBERNETES_SERVICE_HOST`. If that's this node's address, every node
   loses its service routing (DNS, Postgres, LLDAP) while it's down, as
   when the arquitens VM went down on 2026-10-17.
2. On the machine, make the VM's two new volumes:

   ```
   sudo lvcreate -L 32G -n node vg
   sudo lvcreate -L 16G -n node-swap vg
   sudo mkswap -L node-swap /dev/vg/node-swap
   sudo mkfs.btrfs -L node /dev/vg/node
   sudo mkdir -p /mnt/node && sudo mount /dev/vg/node /mnt/node
   for s in root persist large cache dots; do sudo btrfs subvolume create /mnt/node/$s; done
   sudo umount /mnt/node
   ```

3. In the Tailscale admin console, make a one-off pre-auth key tagged for
   hypervisors. ACL: only your devices reach that tag; it reaches nothing.
   Put the key on the machine, pasting it at the prompt:

   ```
   sudo install -m 0400 /dev/stdin /persist/tailscale-hv.authkey
   ```

### Cutover (the node is down ~10 minutes)

4. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`, and
   `ceph osd set noout` (in the Rook toolbox).
5. Make `<node>-hv` the **next boot**, not the running system: deploy it
   with `boot`, not `switch`. A switch would take k3s and `/data` away under
   the running node.
6. Stop the node, copy its identity into the VM's `/persist`, and set the
   machine's copy aside. It is kept aside, not deleted, for the rollback:

   ```
   sudo systemctl stop k3s
   sudo mkdir -p /mnt/node && sudo mount -o subvol=persist /dev/vg/node /mnt/node
   cd /persist
   id=(etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub
       etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub etc/machine-id
       var/lib/tailscale var/lib/agent-auth-hostd ceph-luks.key)
   sudo ls -ld "${id[@]}"     # all eight, or stop here
   findmnt /mnt/node          # vg-node[/persist], or stop here
   sudo cp -a --parents "${id[@]}" var/lib/nixos root/.ssh home/jrt/.ssh /mnt/node/
   sudo mkdir /persist/baremetal
   sudo cp -a --parents "${id[@]}" /persist/baremetal/ && sudo rm -r "${id[@]}"
   readlink -f /nix/var/nix/profiles/system   # must be nixos-system-<node>-hv-...
   ```

   An array, not a word-split string: jrt's shell is zsh, which doesn't
   split an unquoted `$var`. `findmnt /mnt/node` before the copy must show
   `vg-node[/persist]`: unmounted, the copy lands on the machine's root and
   the reboot wipes it.

   Then give the VM's top directories the machine's modes and owners.
   Impermanence gives `/etc`'s parent in the guest the mode of
   `/persist/etc`, and one made `0700` (by the copy, or by the guest's first
   boot) leaves `/etc` root-only: dbus, resolved and NetworkManager fail,
   and the VM never gets a lease:

   ```
   cd /mnt/node
   for d in etc etc/ssh var var/lib home home/jrt root; do
     if [ -d "$d" ] && [ -d "/persist/$d" ]; then
       sudo chmod --reference="/persist/$d" "$d"; sudo chown --reference="/persist/$d" "$d"
     fi
   done
   sudo ls -ld etc var home root /persist/{etc,var,home,root}   # the same, pairwise
   cd / && sudo umount /mnt/node
   ```

   `/persist/baremetal` gets the same fix before a rollback copies it back.

   `var/lib/nixos` (uid and gid allocations) is copied, not moved: both
   machines keep the same uids. The machine boots without the moved files and
   makes itself new ones: ssh host keys, machine-id and a Tailscale login,
   from the key in step 3.
7. `sudo reboot`. The machine comes up as `<node>-hv`: LUKS through the TPM,
   the dongle on its new MAC, Tailscale through the auth key, then
   `node-vm-node`. The VM boots as `<node>` on its Tailscale address, k3s
   rejoins as the same etcd member, `cryptceph` opens, and Rook's OSD comes
   back.
8. Check:
   - `kubectl get node <node>` is Ready, and etcd has three healthy members;
   - `ceph -s` shows the OSD up; then `ceph osd unset noout` and
     `kubectl uncordon <node>`;
   - on the machine, `node-vm log node` is the guest's console;
   - on the machine, the guest's memory is in huge pages:
     `grep -E 'ShmemHugePages|ShmemPmdMapped' /proc/meminfo` shows tens of
     GiB, not 0. Without them crosvm's page tables outgrow the unit's
     memory limit, and the OOM killer takes the VM;
   - in the node, `ls -l ~/.zshrc` is a link into the store, and
     `stat -c %U ~/.config` says jrt (Home Manager's files, linked at boot);
   - delete `/persist/tailscale-hv.authkey`.
9. Reserve the machine's DHCP lease (the table above: its `02:` MAC).
   Its netconsole is already on, in `netconsole.nix`'s hosts map, and goes
   to another machine's node: a machine can't reach its own VM over the
   LAN.

### Rollback (any time before cleanup)

On the machine:
1. `sudo node-vm stop node`.
2. Move `/persist/baremetal/*` back into place: `cp -a` back, overwriting what
   the machine made.
3. Make the last bare-metal generation the next boot:
   `sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration boot`.
4. Reboot.

The bare-metal node finds `/data` and the Ceph disk as the VM left them.
**Never run both.** They share disks and identity.

### Cleanup (after a few quiet days)

- Delete `/persist/baremetal`.
- Make `hosts/<node>` the guest: move `hosts/<node>-node` there, and drop
  `hostDir` and the bare-metal output from `flake.nix`.

## What this doesn't do yet, or hasn't shown

- **Proven, and not.** arquitens has run as a VM since 2026-10-17: the
  disks, the impermanence rollback, `/data` in the initrd, `cryptceph` on a
  virtio disk, and k3s and Tailscale back as themselves. Its cutover is where
  the mount check and the mode fix in step 6 came from. carrack and
  munificent are copies of its config (`hosts/<node>-hv` and `-node` diff
  against arquitens's in their addresses, MACs, disks and PCR 15 only, and
  in the nodes' `serverAddr` and netconsole target). What one cutover can't
  show is the three as VMs together. If a node doesn't come up,
  `node-vm log node` has its console, and the rollback is the way out.
- **No interactive console.** The guest's serial is output only, into the
  journal. A guest that doesn't come up is debugged from that, or rolled back.
- **The iGPU stays on the machine.** immich's machine-learning pods ask for
  an AMD GPU each (three replicas, one per node). Each conversion leaves one
  Pending, and after the last none runs. Move them to CPU (homelab) before
  then.
- **The store is shared whole.** The guest reads the machine's entire store,
  read-only. A store holds no secrets by design. But once the sensitive VM
  shares it, each guest can read the other's system configuration, though not
  its secrets.
- **A guest update is a node reboot.** No in-place switch yet.
- **The network moves in the host kernel (vhost-net).** crosvm's own
  virtio-net (userspace, one queue) moves a packet per syscall. TCP between
  nodes on the LAN rides 64K offloaded frames, 170-195 MB/s; WireGuard's
  ~1.3 KB packets can't, so the tailnet (the nodes' InternalIPs: Cilium's
  tunnel, Ceph, everything between nodes) ran 45-75 MB/s with the macvtap
  dropping 2% of what it received. Its queue at 4096 (`tapQueueLength`) took
  that to ~85 MB/s (2026-10-23). vhost-net (`vhostNet`, on) and mergeable
  RX buffers (`mrg-rxbuf`) are the rest, at the VM's next start. vhost-net's
  price is isolation: the guest's virtqueues are read by the host kernel's
  vhost driver instead of a jailed, unprivileged crosvm process, so a guest
  kernel exploit has more of the host to aim at. `vhostNet = false` takes
  that back, at the throughput. Multiqueue (`vq-pairs`) wouldn't help the
  tailnet: one WireGuard flow hashes to one queue (and crosvm offers no
  multiqueue with vhost-net).
- **A reboot in the guest needs `--extended-status`.** Without it crosvm
  exits 0 for a guest's reset as for a power-off, and the unit, `Restart =
  on-failure`, stayed down: carrack's softdog reset it on 2026-10-22 and it
  was off for 11 hours; `node-rollout`'s reboots go the same way.
  The VMM runs with it now: a reset (32) or crash restarts the unit, a
  power-off (0) doesn't.
