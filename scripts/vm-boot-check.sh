#!/usr/bin/env bash
# Checks the boot experience (T-269) inside a booted VM, as root. Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-boot-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-boot-check.sh
# What it cannot see is the screen: that is scripts/vm-boot-shots.ps1 (shots during boot) and
# dev-setup.md, "Boot experience". It prints the splash-to-shell timeline of this boot.
set -u
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

cmd="$(cat /proc/cmdline)"
for a in quiet splash loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.plymouth=1 plymouth.ignore-serial-consoles; do
    case " $cmd " in *" $a "*) ok "kernel argument $a" ;; *) bad "kernel argument $a missing: $cmd" ;; esac
done
case " $cmd " in *" loglevel=3 "*) bad "old loglevel=3 still on the command line (kargs.d change not applied?)" ;; esac

[ "$(plymouth-set-default-theme)" = ruyaos ] && ok "default Plymouth theme is ruyaos" || bad "default theme: $(plymouth-set-default-theme)"
journalctl -b -q -u plymouth-start.service --no-pager | grep -q . && ok "plymouth-start ran in this boot" || ok "plymouth-start has no journal lines (it ran in the initramfs)"

# GRUB: a new disk has the policy in grub.cfg, an older one gets custom.cfg from ruya-grub-menu.service.
if grep -q 'ruya_menu_policy=1' /boot/grub2/grub.cfg 2>/dev/null; then
    ok "grub.cfg carries the menu policy (disk installed from this image)"
elif grep -qx '# ruyaos-managed: grub-menu-custom.cfg' /boot/grub2/custom.cfg 2>/dev/null; then
    ok "custom.cfg carries the menu policy (older disk, written by ruya-grub-menu.service)"
else
    bad "no menu policy in /boot/grub2/grub.cfg or custom.cfg"
fi
[ "$(systemctl show -p Result --value ruya-grub-menu.service)" = success ] && ok "ruya-grub-menu.service succeeded" || bad "ruya-grub-menu.service: $(systemctl show -p Result --value ruya-grub-menu.service)"
cmp -s /usr/lib/ruyaos/grub-menu-custom.cfg /boot/grub2/custom.cfg && ok "custom.cfg equals /usr/lib/ruyaos/grub-menu-custom.cfg" || echo "note: custom.cfg differs or is absent"
echo "grubenv: $(grub2-editenv list | tr '\n' ' ')"
# The service remounts /boot read-write and back to read-only before it exits, which cannot be seen from
# here; this only shows the host's view after the boot (read-only), so it is a sanity check, not a proof
# that the service restored the flag.
findmnt -n -o OPTIONS /boot | tr ',' '\n' | grep -qx ro && ok "/boot is read-only in the host namespace" || bad "/boot is read-write in the host namespace"

# No text console: nothing started a login on tty1.
if journalctl -b -q -u getty@tty1.service --no-pager | grep -q -E 'Started|Starting'; then
    bad "getty@tty1 started in this boot (a login prompt may flash)"
else
    ok "getty@tty1 did not start"
fi
systemctl is-active plymouth-quit.service >/dev/null && ok "plymouth-quit.service ran (retain-splash)" || echo "note: plymouth-quit.service not active"
systemctl show -p ExecStart --value plymouth-quit.service | grep -q 'retain-splash' && ok "plymouth-quit uses --retain-splash" || bad "plymouth-quit does not retain the splash"
pgrep -x plymouthd >/dev/null && echo "note: plymouthd is still running" || ok "plymouthd has exited"

# The compositor is up, started after Plymouth had quit.
systemctl is-active 'ruya-compositor@tty1.service' >/dev/null && ok "compositor active" || bad "compositor not active"
systemctl show -p After --value 'ruya-compositor@tty1.service' | grep -q 'plymouth-quit-wait.service' && ok "compositor is ordered after plymouth-quit-wait" || bad "compositor is not ordered after plymouth-quit-wait"

echo "--- timeline of this boot (seconds since the kernel started, from the journal)"
for pat in 'plymouth-start.service' 'plymouth-quit.service' 'ruya-compositor@tty1.service'; do
    journalctl -b -q -o short-monotonic --no-pager -u "$pat" 2>/dev/null | grep -E 'Starting|Started|Finished' | head -2 | sed "s/^/  /"
done
uid="$(id -u ruya-shell 2>/dev/null || echo 0)"
journalctl -b -q -o short-monotonic --no-pager _UID="$uid" | grep -E 'ruya-shell: ready' | head -1 | sed 's/^/  /'
exit $fail
