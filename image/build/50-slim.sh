#!/usr/bin/env bash
# Slim the image (T-195): remove what fedora-bootc ships that a living-room console never uses.
# One place for the removals (not edits to the package sets of 20-base/30-codecs), run after
# the NVIDIA step so that nothing installed later pulls a package back in. The reason for each
# group is in docs/image-packages.md.
#
# Safety, in this order:
#  1. the dry run's whole transaction must consist of packages that are on the lists below (an
#     unexpected dependent, like a codec or Qt package, stops the build instead of being removed);
#  2. none of the protected packages may be in it;
#  3. after the real removal the protected packages must still be installed.
set -euo pipefail

# Package name globs to remove. A name that is not installed is skipped (idempotent).
remove=(
    # CPU emulators: binfmt helpers for foreign containers; nothing runs foreign binaries.
    'qemu-user-static*'
    # Cloud and enterprise identity: Active Directory / IPA / LDAP login, Kerberos tools, TPM-bound
    # disk unlock (clevis), cloud agents. Profiles are plain Unix users from useradd (ruya-profiles).
    # (tpm2-tools stays: bootc's dracut config adds the tpm2-tss module, which needs it.)
    'sssd*' adcli gssproxy 'clevis*'
    libipa_hbac libsss_certmap libsss_idmap libsss_nss_idmap libsss_sudo libini_config
    libcollection libdhash libpath_utils libref_array libbasicobjects cyrus-sasl-gssapi
    adcli-selinux jose libjose luksmeta libluksmeta libverto-libev libev c-ares
    NetworkManager-cloud-setup WALinuxAgent-udev
    # Network file system client and its helpers. (samba-client-libs and libsmbclient stay: ffmpeg's
    # libavformat links libsmbclient, so removing them would remove ffmpeg and Qt Multimedia.)
    nfs-utils nfs-client-utils nfsv3-client-utils nfsv4-client-utils nfs-common-utils
    libnfsidmap rpcbind quota quota-nls
    # LVM: udisks2 needs libblockdev-mdraid (so mdadm stays) but not lvm2; the root is a plain xfs
    # partition and Flatpak apps live on it.
    lvm2 device-mapper-persistent-data device-mapper-event device-mapper-event-libs libaio
    # Cloud SDK (123 MB of botocore) and the python libraries only it, sos and the cloud tools used.
    python3-botocore python3-boto3 python3-s3transfer python3-jmespath python3-dateutil
    sos python3-pexpect python3-ptyprocess python3-requests python3-pysocks python3-urllib3
    'python3-urllib3+socks' python3-idna python3-charset-normalizer python3-html2text
    python3-pyyaml python3-six python3-packaging python3-file-magic
    # Daemons and tools of a server or workstation: mDNS, toolbox containers, realtime stall
    # detector, IRQ balancing, iptables-save restore at boot (NetworkManager uses nftables),
    # kernel crash dumps, the image-building tool and the archive repo definitions.
    avahi libdaemon toolbox stalld irqbalance iptables-services
    kdump-utils kexec-tools makedumpfile chunkah fedora-repos-archive
)

# Packages the transaction must never contain (the task's list, plus what ruya-session and the
# update path run). Globs; checked against the dry run and against the final package set.
protected=(
    bootc ostree ostree-libs rpm-ostree systemd systemd-udev systemd-libs greenboot 'greenboot-*'
    NetworkManager NetworkManager-libnm NetworkManager-wifi wpa_supplicant flatpak bluez udisks2 upower
    openssh-server openssh-clients selinux-policy selinux-policy-targeted 'kernel*' 'kmod-*'
    polkit bubblewrap xdg-dbus-proxy python3 python3-libs skopeo podman dbus-broker pipewire
    wireplumber ffmpeg ffmpeg-libs 'qt6-*' 'xorg-x11-drv-nvidia*' 'mesa-*' 'linux-firmware*'
    bootupd dracut grub2-efi-x64 shim-x64 mdadm libblockdev-mdraid cryptsetup 'libsmbclient'
    samba-client-libs libwbclient cloud-utils-growpart plymouth
    pipewire-pulseaudio exfatprogs ntfs-3g 'iwl*-firmware' mediatek-firmware libertas-firmware alsa-sof-firmware
)

# Names of packages that may appear in the transaction without matching `remove`: dependents
# that go with a removal (checked, and listed here, never silently accepted).
allowed_extra=(lvm2-libs)

matches() { # matches NAME GLOB...
    local name="$1" g
    shift
    for g in "$@"; do
        # shellcheck disable=SC2053
        [[ "$name" == $g ]] && return 0
    done
    return 1
}

to_remove=()
for pat in "${remove[@]}"; do
    while read -r n; do
        [ -n "$n" ] && to_remove+=("$n")
    done < <(rpm -qa --qf '%{NAME}\n' "$pat" 2>/dev/null | sort -u)
done
if [ "${#to_remove[@]}" -eq 0 ]; then
    echo "slim: nothing to remove"
    exit 0
fi
echo "slim: removing ${#to_remove[@]} requested packages"

# 1 + 2: the dry run.
plan="$(mktemp)"
trap 'rm -f "$plan"' EXIT
dnf -y remove --assumeno "${to_remove[@]}" >"$plan" 2>&1 || true
cat "$plan"
planned="$(sed -nE 's/^ ([A-Za-z0-9_][^ ]*) +(noarch|x86_64|i686|aarch64) .*/\1/p' "$plan" | sort -u)"
if [ -z "$planned" ]; then
    echo "slim: could not read the dnf transaction"
    exit 1
fi
bad=0
while read -r n; do
    if matches "$n" "${protected[@]}"; then
        echo "slim: REFUSED, the transaction removes protected package: $n"
        bad=1
    elif ! printf '%s\n' "${to_remove[@]}" | grep -qxF "$n" && ! matches "$n" "${allowed_extra[@]}"; then
        echo "slim: REFUSED, the transaction removes a package nobody asked for: $n"
        bad=1
    fi
done <<<"$planned"
[ "$bad" = 0 ] || exit 1

dnf -y remove "${to_remove[@]}"

# 3: still there. Exact names (every one is installed in the image today).
must_stay=(
    bootc ostree rpm-ostree systemd greenboot NetworkManager flatpak bluez udisks2 upower
    openssh-server selinux-policy-targeted kernel-core polkit bubblewrap xdg-dbus-proxy python3
    skopeo podman dbus-broker pipewire wireplumber ffmpeg plymouth mdadm libsmbclient
    samba-client-libs libwbclient cloud-utils-growpart bootupd
)
for p in "${must_stay[@]}"; do
    rpm -q "$p" >/dev/null || { echo "slim: protected package is gone: $p"; exit 1; }
done

# Units that the removed packages enabled leave dangling links in /etc/systemd/system (the
# package scriptlets cannot always run `systemctl disable` while the image builds).
find /etc/systemd/system -xtype l -print -delete
echo "slim: done, $(rpm -qa | wc -l) packages"
