#!/usr/bin/env bash
# Looks at the Profiles service inside a running VM (T-120). Copy it over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-profiles-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-profiles-check.sh [introspect|state|security]
# No argument = state: what the service lists and what is on disk.
set -u
svc=org.ruyaos.Profiles1
path=/org/ruyaos/Profiles1

case "${1:-state}" in
introspect)
    busctl --system introspect "$svc" "$path" "$svc"
    ;;
security)
    systemctl is-active ruya-profiles
    systemd-analyze security ruya-profiles --no-pager | tail -12
    ;;
state)
    echo "--- ListProfiles"
    busctl --system call "$svc" "$path" "$svc" ListProfiles
    echo "--- ActiveProfile"
    busctl --system get-property "$svc" "$path" "$svc" ActiveProfile
    echo "--- /var/lib/ruyaos/profiles.toml"
    if [ -e /var/lib/ruyaos/profiles.toml ]; then
        stat -c '%a %U:%G %n' /var/lib/ruyaos/profiles.toml
        # PINs are stored as argon2id hashes only: show the file with the hashes cut off.
        sed -E 's/(pin_hash *= *"[^"]{0,24})[^"]*/\1…"/' /var/lib/ruyaos/profiles.toml
    else
        echo "(does not exist)"
    fi
    echo "--- unix users ruya-p*"
    getent passwd | grep '^ruya-p' || echo "(none)"
    ls -ld /var/home/ruya-p* 2>/dev/null || echo "(no /var/home/ruya-p*)"
    ;;
*)
    echo "usage: $0 [introspect|state|security]" >&2
    exit 2
    ;;
esac
