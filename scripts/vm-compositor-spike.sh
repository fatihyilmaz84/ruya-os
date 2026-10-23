#!/bin/bash
# T-123 compositor spike (ADR-002), run in the guest as root. Swaps the cage session for
# ruya-compositor-spike@tty1 (ruya-shell as the Wayland compositor on KMS) and starts a test client.
#
#   vm-compositor-spike.sh start    # stop cage, start the spike compositor (socket ruya-0)
#   vm-compositor-spike.sh client   # start the key-logging test client as ruya-shell
#   vm-compositor-spike.sh kill     # end the client (the shell takes the screen back)
#   vm-compositor-spike.sh log [n]  # the compositor's and the client's spike lines
#   vm-compositor-spike.sh stop     # back to the cage session
#
# Drive it from the host with vm-keys.ps1 (letters reach the client; meta_l is Guide) and
# vm-inject-key.py guide (the controller's Guide); see docs/tasks/T-123-compositor-spike.md.
set -uo pipefail
U=$(id -u ruya-shell)
SPIKE=/usr/share/ruya-shell/spike

case "${1:-}" in
start)
  # eglfs opens the input devices itself: let logind ACL them to the active session, only while
  # the spike runs (the rule lives in /run, a tmpfs).
  install -D -m 0644 /usr/share/ruyaos/spike/70-ruya-spike-input.rules /run/udev/rules.d/70-ruya-spike-input.rules
  udevadm control --reload
  udevadm trigger --subsystem-match=input --action=change
  udevadm settle
  systemctl stop ruya-compositor@tty1
  systemctl reset-failed ruya-compositor-spike@tty1 2>/dev/null
  systemctl start ruya-compositor-spike@tty1
  for _ in $(seq 1 30); do
    [ -S /run/user/$U/ruya-0 ] && break
    sleep 1
  done
  systemctl is-active ruya-compositor-spike@tty1
  [ -S /run/user/$U/ruya-0 ] && echo "socket /run/user/$U/ruya-0" || echo "no compositor socket"
  ;;
client)
  # Software rendering, so the client sends shm buffers: llvmpipe has no EGL_WL_bind_wayland_display.
  runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$U WAYLAND_DISPLAY=ruya-0 \
    QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
    /usr/bin/ruya-shell --mock-services --load $SPIKE/KeyClient.qml >/dev/null 2>&1 &
  sleep 6
  pgrep -f "[K]eyClient.qml" >/dev/null && echo "client running" || echo "client failed"
  ;;
kill)
  pkill -f "[K]eyClient.qml"
  sleep 2
  ;;
log)
  journalctl -b -o short-precise _UID=$U --no-pager | grep -E "ruya-spike|spike-client|qml:.*Error" | tail -n "${2:-30}"
  ;;
stop)
  pkill -f "[K]eyClient.qml"
  systemctl stop ruya-compositor-spike@tty1
  rm -f /run/udev/rules.d/70-ruya-spike-input.rules
  udevadm control --reload
  # logind does not take an ACL back when a device loses its uaccess tag: drop the shell user's
  # entries, then let udev and logind re-apply the ACLs of devices that are still tagged.
  for d in /dev/input/event*; do setfacl -x u:ruya-shell "$d" 2>/dev/null; done
  udevadm trigger --subsystem-match=input --action=change
  udevadm settle
  systemctl start ruya-compositor@tty1
  systemctl is-active ruya-compositor@tty1
  ;;
*)
  sed -n '2,12p' "$0"
  exit 2
  ;;
esac
