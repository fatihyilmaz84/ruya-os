#!/usr/bin/env bash
# Turn the container image into a bootable disk/installer with bootc-image-builder.
#   scripts/make-disk.sh [qcow2|raw|anaconda-iso]      -> output/<type>/...
#   scripts/make-disk.sh --check-config                -> only report which config would be used
# Never use `bootc install to-disk /dev/vda` inside a build VM: that is the VM's own disk.
set -euo pipefail
cd "$(dirname "$0")/.."

# Picks the bootc-image-builder config into $config_file and prints which one it is.
# Local dev config (SSH access, git-ignored) wins. Without it the disk would get no SSH key and
# you could not log into it, which is what happens in every fresh worktree, so that is an error
# unless RUYA_NO_DEV_KEY=1 says a keyless disk is intended (CI's image job, release builds).
choose_config() {
    if [[ -f image/bib/config.toml ]]; then
        config_file=image/bib/config.toml
        echo "config: image/bib/config.toml (dev SSH key)"
    elif [[ "${RUYA_NO_DEV_KEY:-}" == 1 ]]; then
        config_file=image/bib/disk.toml
        echo "config: image/bib/disk.toml (RUYA_NO_DEV_KEY=1: keyless disk, no SSH access)"
    else
        {
            echo "make-disk.sh: image/bib/config.toml is missing, so this disk would have no SSH key and you could not log into it."
            echo "  Fix: copy image/bib/config.toml.example to image/bib/config.toml and put your public key in it,"
            echo "       or copy the file from the main checkout (it is git-ignored, so a fresh worktree never has it)."
            echo "  A keyless disk on purpose (CI, release)? Run again with RUYA_NO_DEV_KEY=1."
        } >&2
        return 1
    fi
}

# --check-config: only run the config check above, build nothing.
if [[ "${1:-}" == "--check-config" ]]; then
    choose_config
    exit
fi

type="${1:-qcow2}"
image="${IMAGE:-localhost/ruyaos:dev}"
bib="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"

choose_config   # before anything slow or visible: fail fast
mkdir -p output
# The installer ISO also gets its own kickstart (image/bib/iso-kickstart.toml: use the whole disk
# for /, which Anaconda's autopart does not), appended to the chosen config in a scratch copy.
if [[ "${type}" == "anaconda-iso" ]]; then
    cat "$config_file" image/bib/iso-kickstart.toml > output/bib-iso-config.toml
    config_file=output/bib-iso-config.toml
    echo "config: + image/bib/iso-kickstart.toml (whole-disk root)"
fi
config_args=(-v "$PWD/$config_file:/config.toml:ro")

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
