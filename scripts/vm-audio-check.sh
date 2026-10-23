#!/usr/bin/env bash
# Looks at the audio path inside a running VM (T-121). Copy it over and run it as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-audio-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-audio-check.sh
# Prints: the kernel's sound card, the shell user's PipeWire / WirePlumber / pipewire-pulse
# (the compositor session is started through pam_systemd, so ruya-shell has a user manager),
# `wpctl status` (the sink and the shell's streams), and the shell's audio-related log lines.
# Whether the cues are really played is checked on the host: boot with
# `smoke-test.ps1 -Audio -AudioBackend wav`, press keys with vm-keys.ps1, power the VM off, then
# `python scripts/vm-audio-bursts.py` lists the sounds QEMU recorded.
set -u
uid="$(id -u ruya-shell)"
rt="/run/user/$uid"
as_shell() {
    runuser -u ruya-shell -- env XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" "$@"
}

echo "--- sound cards (kernel)"
cat /proc/asound/cards 2>&1
echo "--- user manager for ruya-shell"
systemctl is-active "user@$uid.service"
ls -ld "$rt" 2>&1
echo "--- user units"
as_shell systemctl --user list-units --no-pager --no-legend 'pipewire*' 'wireplumber*' 2>&1
echo "--- processes"
pgrep -u ruya-shell -a 'pipewire|wireplumber|pipewire-pulse' 2>&1 || echo "(none)"
echo "--- wpctl status"
as_shell wpctl status 2>&1
echo "--- default sink"
as_shell wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1 | grep -E "node.name|node.description|media.class|alsa.card_name" || echo "(no default sink)"
echo "--- shell log: audio, multimedia, sound (count, message)"
journalctl -b -q -o cat _UID="$uid" | grep -iE "qsound|multimedia|audio|pulse|pipewire|ffmpeg|alsa|sound" \
    | grep -v "^spa\.\|libcamera\|^Started \|^Listening on " | sort | uniq -c | sort -rn | head -20
