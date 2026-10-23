#!/usr/bin/env bash
# Checks the power-action policy (T-107) inside a running VM. Copy it over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-power-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-power-check.sh [--power-off]
# Prints: the shell's polkit verdict per action (must be authorized), an ordinary user's verdict
# (must be refused), logind's CanPowerOff for both, and what the shell's own Power backend read.
# With --power-off it then powers the machine off as ruya-shell, exactly as the shell's
# DBusPowerBackend does (logind PowerOff with interactive=false); QEMU should exit.
set -u

pid="$(pgrep -u ruya-shell -x ruya-shell | head -1)"
if [ -z "$pid" ]; then
    echo "no ruya-shell process: is the shell running?" >&2
    exit 1
fi
echo "ruya-shell pid: $pid"

actions="suspend suspend-multiple-sessions reboot reboot-multiple-sessions power-off power-off-multiple-sessions"

verdict() { # verdict <pid> <action-suffix>; pkcheck exits 0 = authorized, 1 = not, 2 = needs authentication
    pkcheck --action-id "org.freedesktop.login1.$2" --process "$1"
    echo "  $2: exit $?"
}

echo "--- polkit: ruya-shell (every line must say exit 0)"
for a in $actions; do verdict "$pid" "$a"; done

id ruya-test-user >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin ruya-test-user
runuser -u ruya-test-user -- sleep 300 &
sleep 1
tpid="$(pgrep -u ruya-test-user -x sleep | head -1)"
echo "--- polkit: ordinary user ruya-test-user, pid $tpid (no line may say exit 0)"
for a in $actions; do verdict "$tpid" "$a"; done
kill "$tpid" 2>/dev/null

can() { runuser -u "$1" -- busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanPowerOff 2>&1; }
echo "--- logind CanPowerOff as ruya-shell:       $(can ruya-shell)"
echo "--- logind CanPowerOff as ruya-test-user:   $(can ruya-test-user)"

echo "--- what the shell's Power backend read at start-up"
journalctl -b -q -o cat _UID="$(id -u ruya-shell)" | grep 'ruya-shell: power' || echo "  (no line)"

userdel ruya-test-user 2>/dev/null

echo "--- modes of what the image ships for this (nothing may be group- or world-writable)"
stat -c '  %a %n' /usr/share/polkit-1/rules.d /usr/share/polkit-1/rules.d/50-ruyaos-power.rules \
    /usr/libexec /usr/libexec/ruyaos /etc/pam.d/ruya-shell /usr/share/dbus-1/system.d/org.ruyaos.Profiles1.conf
bad="$(find /usr/lib/systemd/system/ruya* /usr/lib/sysusers.d/ruyaos.conf /usr/lib/tmpfiles.d/ruyaos.conf \
    /usr/share/dbus-1/system.d/org.ruyaos.* /usr/share/polkit-1/rules.d /usr/libexec/ruyaos /etc/pam.d/ruya-shell \
    /etc/greenboot/greenboot.conf -maxdepth 1 -perm /022)"
[ -z "$bad" ] && echo "  none writable: ok" || echo "  WRITABLE: $bad"

if [ "${1:-}" = "--power-off" ]; then
    echo "--- ruya-test-user PowerOff (must be refused)"
    useradd -M -s /usr/sbin/nologin ruya-test-user
    runuser -u ruya-test-user -- busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager PowerOff b false 2>&1
    userdel ruya-test-user 2>/dev/null
    echo "--- ruya-shell PowerOff (the machine should power off now)"
    runuser -u ruya-shell -- busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager PowerOff b false 2>&1
fi
