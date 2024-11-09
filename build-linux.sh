#!/usr/bin/env nix-shell
#!nix-shell -p podman qemu edk2
#!nix-shell -i bash
# Currently this tries to build for Linux/ARM and the dart packages fail
podman machine init
podman build --progress=plain -t nix-infra-image .
podman run --rm -v "$1:/output" nix-infra-image
