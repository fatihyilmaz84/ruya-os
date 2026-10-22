#!/usr/bin/env bash
# Turn the container image into a bootable disk/installer with bootc-image-builder.
#   scripts/make-disk.sh [qcow2|raw|anaconda-iso]      -> output/<type>/...
# Never use `bootc install to-disk /dev/vda` inside a build VM: that is the VM's own disk.
set -euo pipefail
cd "$(dirname "$0")/.."

type="${1:-qcow2}"
image="${IMAGE:-localhost/ruyaos:dev}"
bib="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"

mkdir -p output
config_args=()
if [[ -f image/bib/config.toml ]]; then
    config_args=(-v "$PWD/image/bib/config.toml:/config.toml:ro")
fi

# bootc-image-builder needs a rootful podman and the image in root's storage.
if [[ $EUID -ne 0 ]]; then sudo=sudo; else sudo=; fi
if ! $sudo podman image exists "${image}"; then
    podman save "${image}" | $sudo podman load
fi

tty_args=()
[[ -t 0 ]] && tty_args=(-it)

$sudo podman run --rm "${tty_args[@]}" --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "$PWD/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${config_args[@]}" \
    "${bib}" \
    --type "${type}" --rootfs xfs \
    "${image}"

$sudo chown -R "$(id -u):$(id -g)" output
echo "disk written under output/"
