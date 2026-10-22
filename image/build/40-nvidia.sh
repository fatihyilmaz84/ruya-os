#!/usr/bin/env bash
# NVIDIA proprietary driver from RPM Fusion, with kernel modules prebuilt for the image's
# kernel (no akmods compile on the user's machine). Harmless on AMD/Intel hardware: the
# modules simply never load. GPUs dropped by the current driver branch are unsupported.
set -euo pipefail

kver="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -n1)"
echo "building NVIDIA modules for kernel ${kver}"

# kernel-devel must match the image kernel exactly; if the base image kernel is older than
# the repos, move the image to the newest kernel first (initramfs is rebuilt in 90-*.sh).
if ! dnf -y install "kernel-devel-${kver}"; then
    dnf -y upgrade kernel kernel-core kernel-modules kernel-modules-core
    kver="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)"
    dnf -y install "kernel-devel-${kver}"
fi

dnf -y install --setopt=install_weak_deps=False \
    akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-power libva-nvidia-driver

# Ephemeral signing key for this build. TODO(Phase 6): stable project key from CI secrets.
kmodgenca -a -f

# Build and install kmod-nvidia-<kver> now. akmods signs with a key it generates; Secure
# Boot needs that key enrolled via MOK (01-platform §2.3), so the public cert is shipped.
akmods --force --kernels "${kver}" --kmod nvidia
modinfo -k "${kver}" nvidia >/dev/null    # fail the build if the module is missing

install -Dm644 /etc/pki/akmods/certs/public_key.der /usr/share/ruyaos/secureboot/akmods-nvidia.der

# Suspend/resume helpers that ship with the driver.
systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service || true

dnf -y remove "kernel-devel-${kver}" akmods akmod-nvidia || true
# The akmods build user outlives its package; drop it so /etc/passwd only holds accounts that
# sysusers.d declares (`bootc container lint`: sysusers).
userdel akmods 2>/dev/null || true
groupdel akmods 2>/dev/null || true

# Never ship the private signing key: anyone holding it could sign modules that
# MOK-enrolled machines would trust.
rm -rf /etc/pki/akmods/private
test ! -e /etc/pki/akmods/private
