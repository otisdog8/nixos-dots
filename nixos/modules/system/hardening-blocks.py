# Writes hardening.nix's generated modprobe.d file (blocksConf) at build time:
# `blacklist` + `install <name> false` for every module named in the request
# (exact names or fnmatch patterns) or found under one of its path prefixes in
# the kernel's modules.order, except the kept ones and everything they need.
#
# Kept: the request's keep names, every module the system loads by name, and
# every out-of-tree module (nvidia, v4l2loopback, the nvgpu kmod, drbd 9), each
# with its whole dependency closure from the system's modules.dep. kmod runs a
# dependency's install line too, so blocking a dependency would block them.
#
# Names asked for that this kernel doesn't have are listed as comments: a
# patterns' check, and the record of what differs between kernels.
import fnmatch
import glob
import json
import sys

req_path, order_dir, dep_dir, false, out = sys.argv[1:]
req = json.load(open(req_path))


def norm(n):
    return n.replace("-", "_")


def name(path):
    return norm(path.rsplit("/", 1)[-1].split(".ko")[0])


[order] = glob.glob(f"{order_dir}/lib/modules/*/modules.order")
[dep] = glob.glob(f"{dep_dir}/lib/modules/*/modules.dep")

in_tree = {}  # name -> path in the kernel's tree
for line in open(order):
    line = line.strip()
    if line:
        in_tree[name(line)] = line

deps = {}
out_of_tree = set()
for line in open(dep):
    mod, _, rest = line.partition(":")
    n = name(mod)
    deps[n] = [name(d) for d in rest.split()]
    if not mod.startswith("kernel/"):
        out_of_tree.add(n)

keep = set()
todo = [norm(k) for k in req["keep"]] + sorted(out_of_tree)
todo += [m for m in deps for p in req["keepPatterns"] if fnmatch.fnmatchcase(m, norm(p))]
while todo:
    m = todo.pop()
    if m not in keep:
        keep.add(m)
        todo += deps.get(m, [])

want = set()
missing = []
for n in req["names"]:
    n = norm(n)
    hits = [m for m in in_tree if fnmatch.fnmatchcase(m, n)] if any(c in n for c in "*?[") else ([n] if n in in_tree else [])
    if not hits:
        missing.append(n)
    want.update(hits)
for p in req["prefixes"]:
    hits = {m for m, path in in_tree.items() if path.startswith(p)}
    if not hits:
        missing.append(p)
    want |= hits
want -= {norm(x) for x in req["exclude"]}
want -= out_of_tree

blocked = sorted(want - keep)
kept = sorted(want & keep)
blacklist_only = sorted({norm(x) for x in req["blacklistOnly"]})
if not blocked:
    sys.exit("nothing to block: wrong module tree?")

with open(out, "w") as f:
    for m in blocked:
        f.write(f"blacklist {m}\ninstall {m} {false}\n")
    # Skipped by systemd-modules-load, still loadable as a dependency.
    for m in blacklist_only:
        f.write(f"blacklist {m}\n")
    f.write(f"# kept (needed by something loaded): {' '.join(kept) or '-'}\n")
    f.write(f"# not in this kernel: {' '.join(sorted(set(missing))) or '-'}\n")
