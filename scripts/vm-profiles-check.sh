#!/usr/bin/env bash
# Looks at the Profiles service inside a running VM (T-120). Copy it over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-profiles-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-profiles-check.sh [introspect|state|security|create]
# No argument = state: what the service lists and what is on disk.
# create: on an empty store, creates an admin "Check Admin" (PIN 1234) and a standard profile
# "Check Kid" over the bus as root (no UI), then prints the state and the modes of the account
# files useradd rewrote (T-126: the unit's UMask must not leak into them).
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
create)
    echo "--- CreateProfile: first admin (empty store, no admin credentials needed)"
    busctl --system call "$svc" "$path" "$svc" CreateProfile sssss "" "" "Check Admin" admin 1234
    admin="$(busctl --system call "$svc" "$path" "$svc" ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
    echo "--- CreateProfile: standard profile, with the admin ($admin) PIN"
    busctl --system call "$svc" "$path" "$svc" CreateProfile sssss "$admin" 1234 "Check Kid" standard ""
    bash "$0" state
    echo "--- account files (expect 644 passwd/group, 0 shadow/gshadow)"
    stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow
    ;;
lifecycle)
    # T-118: after `create`, rename and delete the standard profile (p2) as the admin (p1, PIN 1234),
    # then show that the admin is refused for its own deletion and that the Unix user and home are gone.
    echo "--- RenameProfile p2 -> 'Renamed Kid'"
    busctl --system call "$svc" "$path" "$svc" RenameProfile ssss p1 1234 p2 "Renamed Kid"
    busctl --system call "$svc" "$path" "$svc" ListProfiles
    echo "--- DeleteProfile p1 (last admin): expect not-allowed"
    busctl --system call "$svc" "$path" "$svc" DeleteProfile sss p1 1234 p1
    echo "--- DeleteProfile p2"
    busctl --system call "$svc" "$path" "$svc" DeleteProfile sss p1 1234 p2
    bash "$0" state
    echo "--- account files (expect 644 passwd/group, 0 shadow/gshadow)"
    stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow
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
    echo "usage: $0 [introspect|state|security|create|lifecycle]" >&2
    exit 2
    ;;
esac
