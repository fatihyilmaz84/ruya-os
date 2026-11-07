#!/usr/bin/env bash
# The boot experience (T-269) is in the built image: Plymouth theme and plugin, the theme in the
# initramfs, the silent kernel arguments, the GRUB menu policy files and the units.
#   scripts/check-boot-config.sh [image]      (in WSL, repo root; default localhost/ruyaos:dev)
# Exit 1 lists what is missing. The source side is scripts/lint-boot.ps1; the disk side is
# scripts/vm-boot-check.sh (run in a booted VM).
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:-localhost/ruyaos:dev}"

inner="$(mktemp)"
trap 'rm -f "$inner"' EXIT
cat > "$inner" <<'EOF'
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }
t=/usr/share/plymouth/themes/ruyaos
for f in ruyaos.plymouth ruyaos.script bg.png wordmark.png bar.png glow.png; do
    [ -s "$t/$f" ] && ok "theme file $f" || bad "theme file $f missing"
done
[ -s /usr/lib64/plymouth/script.so ] && ok "plymouth script plugin" || bad "script.so missing"
[ "$(plymouth-set-default-theme)" = ruyaos ] && ok "default theme is ruyaos" || bad "default theme is $(plymouth-set-default-theme)"
grep -qx 'Theme=ruyaos' /etc/plymouth/plymouthd.conf && ok "plymouthd.conf: Theme=ruyaos" || bad "plymouthd.conf does not select ruyaos"
kver="$(ls /usr/lib/modules | sort -V | tail -n1)"
list="$(lsinitrd "/usr/lib/modules/$kver/initramfs.img")"
for f in themes/ruyaos/ruyaos.script themes/ruyaos/wordmark.png themes/ruyaos/bg.png plymouth/script.so; do
    grep -q "$f" <<<"$list" && ok "initramfs holds $f" || bad "initramfs lacks $f"
done
k=/usr/lib/bootc/kargs.d/10-ruyaos.toml
for a in quiet splash loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.plymouth=1 plymouth.ignore-serial-consoles; do
    grep -q "\"$a\"" "$k" && ok "karg $a" || bad "karg $a missing"
done
g=/usr/lib/bootupd/grub2-static/configs.d/07_ruyaos-menu.cfg
grep -q 'timeout_style=hidden' "$g" && grep -q 'ruya_menu_policy=1' "$g" && ok "bootupd static GRUB config 07_ruyaos-menu.cfg" || bad "$g missing or wrong"
[ -f /usr/lib/ruyaos/grub-menu-custom.cfg ] && [ -x /usr/libexec/ruyaos/grub-menu-sync ] && ok "grub-menu-custom.cfg and grub-menu-sync" || bad "custom.cfg source or sync script missing"
systemctl is-enabled ruya-grub-menu.service >/dev/null && ok "ruya-grub-menu.service enabled" || bad "ruya-grub-menu.service not enabled"
systemctl cat plymouth-quit.service | grep -q 'plymouth quit --retain-splash' && ok "plymouth-quit retains the splash" || bad "plymouth-quit does not retain the splash"
systemctl cat 'ruya-compositor@tty1.service' | grep -q '^After=.*plymouth-quit-wait.service' && ok "compositor starts after plymouth-quit-wait" || bad "compositor is not ordered after plymouth-quit-wait"
systemd-analyze verify ruya-grub-menu.service 'ruya-compositor@tty1.service' plymouth-quit.service 2>&1 | grep -v -E 'Failed to (create|open|connect)|Cannot determine cgroup' && bad "systemd-analyze verify complained" || ok "systemd-analyze verify is clean"
exit $fail
EOF
podman run --rm -v "$inner:/check.sh:ro" "$image" bash /check.sh
