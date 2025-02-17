#!/usr/bin/env bash

select server in recusant excelsior
do
	sudo nixos-rebuild switch --flake $(dirname $0) --build-host jrt@$server
done
