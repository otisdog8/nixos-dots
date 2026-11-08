#!/usr/bin/env bash
# Switch this host, building its closure on one of the servers.
#
# A server without the 32-bit ABI (hardening ia32Emulation off, as on
# recusant: Nix's extra-platforms is empty there) can't build i686
# derivations, and a desktop's closure has some that no binary cache has
# (unfree 32-bit driver and Steam parts, anything an overlay touches). Such a
# server is offered only when this host's closure has no i686 derivation.
set -euo pipefail

flake=$(dirname "$(realpath "$0")")
host=$(hostname)
servers=(recusant excelsior galaxy)

# The platforms the server's Nix builds for besides its own, as it runs now.
extra_platforms() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 "jrt@$1" nix config show extra-platforms
}

needs_i686() {
	local drv
	drv=$(nix eval --raw "$flake#nixosConfigurations.\"$host\".config.system.build.toplevel.drvPath")
	nix derivation show -r "$drv" \
		| jq -e '(.derivations // .) | any(.[]; .system == "i686-linux")' >/dev/null
}

usable=()
no_i686=()
for s in "${servers[@]}"; do
	[ "$s" = "$host" ] && continue
	if ! platforms=$(extra_platforms "$s"); then
		echo "$s: unreachable, skipped" >&2
		continue
	fi
	if [[ " $platforms " == *" i686-linux "* ]]; then
		usable+=("$s")
	else
		no_i686+=("$s")
	fi
done

if [ ${#no_i686[@]} -gt 0 ]; then
	echo "Checking $host's closure for i686 derivations (${no_i686[*]} can't build them)..." >&2
	if needs_i686; then
		echo "$host needs i686: not offering ${no_i686[*]}" >&2
	else
		usable+=("${no_i686[@]}")
	fi
fi

if [ ${#usable[@]} -eq 0 ]; then
	echo "No usable build host." >&2
	exit 1
fi

select server in "${usable[@]}"; do
	[ -n "$server" ] || continue
	sudo nixos-rebuild switch --flake "$flake" --build-host "jrt@$server"
	break
done
