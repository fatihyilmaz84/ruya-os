#!/usr/bin/env bash
# Regrowth guard (T-195): the build fails when a package the image must not carry is installed,
# or a unit nobody has a reason for is enabled. Prints the package count and /usr size at the end.
# Why each pattern is banned: docs/image-packages.md.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# Banned package name globs. Exceptions are exact names, below.
banned=(
    'gnome-*' 'kde-*' 'plasma-*' 'xfce*' 'lxqt-*' 'mate-*' 'cinnamon*' gdm sddm lightdm
    cups 'cups-client*' 'cups-filters*' 'cups-browsed' 'sane-*' hplip
    firewalld 'cockpit*'
    'qemu-user*'
    'sssd*' 'samba' 'samba-*' realmd adcli 'clevis*'
    nfs-utils rpcbind avahi toolbox lvm2 dmraid
    'python3-botocore' 'python3-boto3' 'python3-s3transfer'
    kdump-utils 'xorg-x11-server*'
)
# Allowed although they match: ffmpeg's libavformat links libsmbclient, which needs these.
# (samba-client-libs etc. cannot go without removing ffmpeg and Qt Multimedia, see 50-slim.sh.)
exceptions=(samba-client-libs samba-common samba-core-libs samba-ndr-libs)

found=0
while read -r name; do
    for pat in "${banned[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$name" == $pat ]]; then
            skip=0
            for e in "${exceptions[@]}"; do [ "$name" = "$e" ] && skip=1; done
            if [ "$skip" = 0 ]; then
                echo "98-guard: banned package installed: $name (pattern $pat)"
                found=1
            fi
        fi
    done
done < <(rpm -qa --qf '%{NAME}\n' | sort -u)

# Enabled units must be in enabled-units.txt.
allowed="$(sed -E 's/#.*//; s/^[[:space:]]+//' "$here/enabled-units.txt" | awk 'NF {print $1}' | sort -u)"
for scope in "" "--global"; do
    while read -r unit _; do
        [ -n "$unit" ] || continue
        if ! grep -qxF "$unit" <<<"$allowed"; then
            echo "98-guard: enabled unit without a reason: $unit ${scope:+(user)} (add it to image/build/enabled-units.txt with a reason, or disable it in system-preset/45-ruyaos.preset)"
            found=1
        fi
    done < <(systemctl $scope list-unit-files --state=enabled --no-legend)
done

# Dangling enablement links (a removed package's unit).
if [ -n "$(find /etc/systemd/system -xtype l -print 2>/dev/null)" ]; then
    echo "98-guard: dangling links in /etc/systemd/system:"
    find /etc/systemd/system -xtype l -print
    found=1
fi

echo "98-guard: $(rpm -qa | wc -l) packages, /usr $(du -sx --block-size=1M /usr | cut -f1) MiB"
[ "$found" = 0 ] || { echo "98-guard: FAILED"; exit 1; }
echo "98-guard: ok"
