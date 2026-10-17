# Cluster nodes as VMs

Each k3s machine (arquitens, carrack, munificent) becomes a hypervisor,
`<machine>-hv`, that runs its k3s node as a VM and nothing else
(`modules/system/node-vm.nix`). Later it runs a second VM beside it, the
sensitive cluster's node. Root in a node is then root in its VM, not on the
machine: one cluster's node is no way into the other's. That holds only while
the machine stays out of reach. It has no agent-auth hostd, no k3s, no libvirt
and no agent VM, and only jrt can ssh in.

The node keeps being the node: the same hostname, etcd member, Tailscale
address, Rook OSD and mon, and local PVs. Its state was always on disks of
its own (XFS `/data`, the SATA Ceph SSD), and the VM gets those disks whole.
What made the machine *that node* (ssh host keys, Tailscale state, machine-id,
hostd's pairing, the Ceph LUKS key, the LAN MAC and so its DHCP lease) moves
into the VM. The machine starts over as `<machine>-hv`.

| | machine (`hosts/arquitens-hv`) | node VM (`hosts/arquitens-node`, hostname `arquitens`) |
|---|---|---|
| boots | Secure Boot, TPM-unlocked LUKS, as before | directly: kernel, initrd, `init=` from the machine's store |
| store | its own | the machine's, read-only over virtio-fs |
| disks | NVMe: ESP, LUKS → vg: `pool`, `swap` | `vg/node` (32G btrfs: root, persist, large, cache, dots), `vg/node-swap`, `vg/data`, the SATA SSD |
| LAN | dongle with a new MAC (02:24:27:88:a9:c4), new lease | macvtap with the dongle's MAC: 10.0.0.10 |
| memory | ~4 GiB | 46 GiB (room for the sensitive VM: ~8 GiB) |

Deploying the node from now on means rebuilding `arquitens-hv`, which builds
the guest. Then run `sudo node-vm restart node` on the machine, which reboots
the node. A rebuild alone never restarts it.

## Converting arquitens

**Do one machine per sitting.** While a machine is converting, etcd runs on
two members and Ceph on two OSDs. A second failure in that window stops
writes. Have fresh backups, and wait for `HEALTH_OK` and three healthy etcd
members before starting the next machine.

### Before (nothing stops)

1. Push the commits, and build `.#arquitens-hv` (it builds the guest too).
2. On arquitens, make the VM's two new volumes:

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

4. `kubectl drain arquitens --ignore-daemonsets --delete-emptydir-data`, and
   `ceph osd set noout` (in the Rook toolbox).
5. Make `arquitens-hv` the **next boot**, not the running system: deploy it
   with `boot`, not `switch`. A switch would take k3s and `/data` away under
   the running node.
6. Stop the node, copy its identity into the VM's `/persist`, and set the
   machine's copy aside. It is kept aside, not deleted, for the rollback:

   ```
   sudo systemctl stop k3s
   sudo mount -o subvol=persist /dev/vg/node /mnt/node
   cd /persist
   id="etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub
       etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub etc/machine-id
       var/lib/tailscale var/lib/agent-auth-hostd ceph-luks.key"
   sudo cp -a --parents $id var/lib/nixos root/.ssh home/jrt/.ssh /mnt/node/
   sudo mkdir /persist/baremetal
   sudo cp -a --parents $id /persist/baremetal/ && sudo rm -r $id
   sudo umount /mnt/node
   ```

   `var/lib/nixos` (uid and gid allocations) is copied, not moved: both
   machines keep the same uids. The machine boots without the moved files and
   makes itself new ones: ssh host keys, machine-id and a Tailscale login,
   from the key in step 3.
7. `sudo reboot`. The machine comes up as arquitens-hv: LUKS through the TPM,
   the dongle on its new MAC, Tailscale through the auth key, then
   `node-vm-node`. The VM boots as arquitens on 100.126.30.73, k3s rejoins as
   the same etcd member, `cryptceph` opens, and Rook's OSD comes back.
8. Check:
   - `kubectl get node arquitens` is Ready, and etcd has three healthy members;
   - `ceph -s` shows the OSD up; then `ceph osd unset noout` and
     `kubectl uncordon arquitens`;
   - on the machine, `node-vm log node` is the guest's console;
   - delete `/persist/tailscale-hv.authkey`.
9. Reserve the machine's new DHCP lease. Add `arquitens-hv` to
   `netconsole.nix`'s hosts map and turn netconsole on in
   `hosts/arquitens-hv`.

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
- Make `hosts/arquitens` the guest: move `hosts/arquitens-node` there, and drop
  `hostDir` and the bare-metal output from `flake.nix`.

## What this doesn't do yet, or hasn't shown

- **Never booted.** It was written where there is no KVM. Of everything here,
  the macvtap handed to crosvm as a tap fd, inside the VMM's private network
  namespace, is what's least certain. If the VM has no network, its console in
  `node-vm log node` will say so, and the rollback is the way out.
- **No interactive console.** The guest's serial is output only, into the
  journal. A guest that doesn't come up is debugged from that, or rolled back.
- **The iGPU stays on the machine.** immich's machine-learning pod asks for an
  AMD GPU; once the last machine converts, no node has one. Move it to CPU
  (homelab) before then.
- **The store is shared whole.** The guest reads the machine's entire store,
  read-only. A store holds no secrets by design. But once the sensitive VM
  shares it, each guest can read the other's system configuration, though not
  its secrets.
- **A guest update is a node reboot.** No in-place switch yet.
