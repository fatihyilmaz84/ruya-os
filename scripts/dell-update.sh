#!/usr/bin/env bash
# Update the Dell test machine with the oci-archive route and print a short
# summary (docs/dev-setup.md "When to build the ISO").
# Usage: scripts/dell-update.sh <version> [host]   (Git Bash or WSL)
# Needs /f/RuyaOS-tmp/ruyaos-<version>.oci (WSL: /mnt/f/...) and the key
# ~/.ssh/ruyaos_dev. The Dell is a pure test machine (CLAUDE.md, Host).
set -u
VER="${1:?version, e.g. 0.0.60}"
HOST="${2:-192.168.178.109}"
OCI="/f/RuyaOS-tmp/ruyaos-$VER.oci"
[ -f "$OCI" ] || OCI="/mnt/f/RuyaOS-tmp/ruyaos-$VER.oci"
[ -f "$OCI" ] || { echo "archive missing: $OCI"; exit 1; }
SSHO="-i $HOME/.ssh/ruyaos_dev -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
r() { ssh $SSHO "root@$HOST" "$@"; }
REMOTE="/var/tmp/ruyaos-$VER.oci"

scp $SSHO "$OCI" "root@$HOST:$REMOTE" || { echo "UPDATE FAILED: scp"; exit 1; }
r "bootc switch --transport oci-archive $REMOTE" > /tmp/dell-switch.log 2>&1 || { tail -5 /tmp/dell-switch.log; echo "UPDATE FAILED: switch"; exit 1; }
r "systemctl reboot" >/dev/null 2>&1
sleep 30
up=0
for _ in $(seq 1 60); do r true 2>/dev/null && { up=1; break; }; sleep 5; done
[ "$up" = 1 ] || { echo "UPDATE FAILED: Dell did not come back"; exit 1; }
# let greenboot and the shell settle
for _ in $(seq 1 40); do
  s=$(r "systemctl is-system-running" 2>/dev/null)
  case "$s" in running|degraded) break;; esac; sleep 5
done
sleep 20
r 'bash -s' <<'EOF' 2>&1 | head -n 15
echo "booted/rollback: $(bootc status --json | python3 -c 'import json,sys;j=json.load(sys.stdin)["status"];f=lambda k:(j.get(k) or {}).get("image",{}).get("version");print(f("booted"),"/",f("rollback"))')"
echo "system: $(systemctl is-system-running)"
echo "greenboot: $(systemctl is-active greenboot-healthcheck.service greenboot-status.service 2>&1 | tr '\n' ' ')"
echo "failed: $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
echo "ruya-shell: $(pgrep -x ruya-shell >/dev/null && echo running || echo NOT-running)  compositor: $(systemctl is-active 'ruya-compositor@tty1')"
pid=$(pgrep -x bluetoothd | head -1)
if [ -n "$pid" ]; then
  a=$(awk '{print $14+$15}' /proc/$pid/stat); sleep 10; b=$(awk '{print $14+$15}' /proc/$pid/stat)
  echo "bluetoothd: $(( (b-a) )) ticks in 10 s (about $(( (b-a)/10 )) % of one core)"
else echo "bluetoothd: not running"; fi
sp=$(pgrep -x ruya-shell | head -1)
# The picker's blobs drift for 30 s after the shell starts (LiquidGate): 16-40 % GPU. Measure the
# resting picker, 40 s after the shell's start (T-455: 0.0.65/0.0.66 "regression" was this).
if [ -n "$sp" ]; then
  while [ "$(ps -o etimes= -p "$sp" | tr -d ' ')" -lt 40 ]; do sleep 2; done
  fd=$(grep -l drm-engine-render /proc/$sp/fdinfo/* 2>/dev/null | head -1)
  if [ -n "$fd" ]; then
    a=$(awk '/drm-engine-render/{print $2}' "$fd"); sleep 10; b=$(awk '/drm-engine-render/{print $2}' "$fd")
    echo "ruya-shell render: $(( (b-a)/1000000 )) ms GPU in 10 s ($(( (b-a)/100000000 )) % busy)"
  else echo "ruya-shell render: no drm fdinfo"; fi
fi
EOF
