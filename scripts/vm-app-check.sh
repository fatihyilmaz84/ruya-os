#!/bin/bash
# A Wayland test app in the VM (T-130), run in the guest as root. ruya-shell is the compositor of
# the default session (ruya-compositor@tty1); this starts the key-logging test client
# (vm-key-client.qml, copied next to this script) as ruya-shell, so the shell shows it fullscreen
# in its app layer and the key routing can be checked.
#
#   vm-app-check.sh client   # start the test client (sign in first: an app gets focus only then)
#   vm-app-check.sh kill     # end the client (the shell takes the screen back)
#   vm-app-check.sh log [n]  # what the compositor and the client saw
#   vm-app-check.sh state    # the session: no cage, the socket, the input ACLs
#   vm-app-check.sh flow     # after Guide, Back, Guide, Resume, Guide, Home was driven: did the quick menu take the focus and give it back (T-147)
#
# Drive it from the host with vm-keys.ps1 (letters reach the client; meta_l is Guide) and
# vm-inject-key.py guide (the controller's Guide); see docs/dev-setup.md, "Test app in the VM".
set -uo pipefail
U=$(id -u ruya-shell)
HERE=$(cd "$(dirname "$0")" && pwd)
CLIENT=/var/tmp/vm-key-client.qml

case "${1:-}" in
client)
  # Readable by ruya-shell (root's home is not).
  install -m 0644 "$HERE/vm-key-client.qml" "$CLIENT"
  # Software rendering, so the client sends shm buffers: llvmpipe has no EGL_WL_bind_wayland_display.
  runuser -u ruya-shell -- env XDG_RUNTIME_DIR=/run/user/$U WAYLAND_DISPLAY=ruya-0 \
    QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
    /usr/bin/ruya-shell --load "$CLIENT" >/dev/null 2>&1 &
  sleep 6
  pgrep -f "[v]m-key-client.qml" >/dev/null && echo "client running" || echo "client failed"
  ;;
kill)
  pkill -f "[v]m-key-client.qml"
  sleep 2
  ;;
log)
  journalctl -b -o short-precise _UID=$U --no-pager | grep -E "ruya-compositor|test-client|qml:.*Error" | tail -n "${2:-40}"
  ;;
flow)
  # The quick menu over the client (T-147). Drive first: sign in, `client`, then Guide, Back, Guide,
  # Resume (Return on the first row), Guide, Home (Down, Return). The client has no Library card, so
  # it cannot be resumed from Home (the menu has no app part behind Home): `kill` it afterwards.
  # Then run this: it counts what the compositor logged. The menu list takes the focus once per
  # Guide (3); the client gains the focus at its start and at each close of the menu over it (3: start,
  # Back, Resume) and loses it at each Guide (3).
  log=$(journalctl -b -o short-precise _UID=$U --no-pager | grep -E "ruya-compositor: (app focus|focus systemActions)")
  menu=$(grep -c "focus systemActions" <<<"$log")
  gained=$(grep -c "app focus .* true" <<<"$log")
  lost=$(grep -c "app focus .* false" <<<"$log")
  echo "menu focused: $menu, client focus gained: $gained, lost: $lost"
  if [ "$menu" -ge 3 ] && [ "$gained" -ge 3 ] && [ "$lost" -ge 3 ]; then
    echo "quick menu flow: ok"
  else
    echo "quick menu flow: FAILED (expected menu >= 3, gained >= 3, lost >= 3)"
    exit 1
  fi
  ;;
state)
  echo "cage processes: $(pgrep -c cage)"
  echo "ruya-shell processes: $(pgrep -u ruya-shell -c -x ruya-shell)"
  systemctl is-active ruya-compositor@tty1
  [ -S /run/user/$U/ruya-0 ] && echo "socket /run/user/$U/ruya-0" || echo "no compositor socket"
  echo "input devices with a ruya-shell ACL: $(for d in /dev/input/event*; do getfacl -p "$d" 2>/dev/null | grep -q '^user:ruya-shell:' && echo "$d"; done | wc -l) of $(ls /dev/input/event* | wc -l)"
  loginctl list-sessions --no-legend
  ;;
*)
  sed -n '2,14p' "$0"
  exit 2
  ;;
esac
