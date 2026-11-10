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

state=/var/lib/ruya-shell/.local/state/ruya-devices   # the state directory of the ruya-shell user unit
# --- T-322: the output policy and the saved choice (ruya-devices, Devices1.Audio)
dev_call() { busctl --system call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Audio "$@" 2>&1; }
default_node() { as_shell wpctl inspect @DEFAULT_AUDIO_SINK@ 2>&1 | sed -n 's/.*node.name = "\(.*\)"/\1/p' | head -1; }
echo "--- outputs (ListOutputs)"
dev_call ListOutputs
echo "--- default sink before: $(default_node)"
echo "--- saved choice file"
cat "$state/outputs.toml" 2>&1 || echo "(none: the policy table decides)"
# Prints "<id> <is_default> <is_saved>" of the first active output of the wanted kind (python3 reads busctl's JSON).
pick_output() {
    busctl --system --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Audio ListOutputs 2>/dev/null         | python3 -c '
import json, sys
kind = sys.argv[1]
rows = [{k: v["data"] for k, v in o.items()} for o in json.load(sys.stdin)["data"][0]]
rows = [o for o in rows if o.get("active")]
if kind != "any":
    rows = [o for o in rows if o.get("kind") == kind]
if rows:
    o = rows[0]
    print(o["id"], str(o["is_default"]).lower(), str(o["is_saved"]).lower())
' "$1"
}
policy_pick="$(pick_output speaker)"
[ -n "$policy_pick" ] || policy_pick="$(pick_output any)"
set -- $policy_pick
out_id="${1:-}"
was_default="${2:-}"
if [ -z "$out_id" ]; then
    echo "AUDIO_SAVED_OUTPUT_FAIL (no active output in ListOutputs)"
else
    echo "--- the speaker/first active output $out_id: is_default=$was_default (the policy table's pick before any choice; must be true for the speaker)"
    status="$(dev_call SetOutput s "$out_id")"
    echo "--- SetOutput $out_id -> $status"
    echo "--- restarting pipewire and wireplumber"
    as_shell systemctl --user restart pipewire.service wireplumber.service 2>&1
    sleep 8
    after="$(default_node)"
    set -- $(busctl --system --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Audio ListOutputs 2>/dev/null         | python3 -c '
import json, sys
want = sys.argv[1]
for o in json.load(sys.stdin)["data"][0]:
    o = {k: v["data"] for k, v in o.items()}
    if o.get("id") == want:
        print(o["id"], str(o["is_default"]).lower(), str(o["is_saved"]).lower())
' "$out_id")
    echo "after the restart: $out_id is_default=${2:-?} is_saved=${3:-?}, default sink node=$after"
    if [ "$status" = 's "ok"' ] && [ "$was_default" = true ] && [ "${2:-}" = true ] && [ "${3:-}" = true ] && [ -n "$after" ]; then
        echo "AUDIO_SAVED_OUTPUT_OK"
    else
        echo "AUDIO_SAVED_OUTPUT_FAIL"
    fi
    echo "--- ResetOutputChoice -> $(dev_call ResetOutputChoice)"
fi

# --- T-347: the first-start volume is high, set once (marker), and a volume set by hand survives restarts
vol_of() { as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>&1 | sed -n 's/^Volume: \([0-9.]*\).*/\1/p'; }
echo "--- first-start volume (T-347)"
marker="$state/first-volume-done"
vol0="$(vol_of)"
echo "volume before touching it: $vol0 (a fresh disk: >= 0.95)"
if [ -e "$marker" ] && awk -v v="${vol0:-0}" 'BEGIN { exit !(v >= 0.95) }'; then
    echo "AUDIO_FIRST_VOLUME_OK (marker $(stat -c %y "$marker"), volume $vol0)"
else
    echo "AUDIO_FIRST_VOLUME_FAIL (marker present: $([ -e "$marker" ] && echo yes || echo NO) at $marker; volume $vol0; on a disk that was used before, the volume may have been lowered by hand)"
fi
as_shell wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.30 2>&1
echo "--- volume set by hand: $(vol_of); letting WirePlumber save it, then restarting pipewire and wireplumber, then ruya-devices"
sleep 12   # WirePlumber saves its state a few seconds after a change
as_shell systemctl --user restart pipewire.service wireplumber.service 2>&1
sleep 10
echo "after pipewire+wireplumber restart: $(vol_of)"
as_shell systemctl --user restart ruya-devices.service 2>&1
sleep 8
after_vol="$(vol_of)"
echo "after ruya-devices restart: $after_vol"
case "$after_vol" in
    0.3|0.30|0.29) echo "AUDIO_VOLUME_KEPT_OK" ;;
    *) echo "AUDIO_VOLUME_KEPT_FAIL (set 0.30, now $after_vol)" ;;
esac

# --- T-449: microphones (Devices1.Audio ListInputs / SetInput / InputMuted). Needs a capture device in the VM
# (QEMU with -Audio gives it one); without one the list is empty and this part says so.
echo "--- microphones (T-449)"
dev_prop() { busctl --system "$1" org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Audio InputMuted "${@:2}" 2>&1; }
src_mute_of() { as_shell wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>&1 | grep -q MUTED && echo true || echo false; }
echo "wpctl sources:"; as_shell wpctl status 2>&1 | sed -n '/Sources:/,/Filters:\|Streams:/p' | head -12
dev_call ListInputs
# "<id> <is_default>" of the default microphone from ListInputs.
default_input="$(busctl --system --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Audio ListInputs 2>/dev/null         | python3 -c '
import json, sys
for o in json.load(sys.stdin)["data"][0]:
    o = {k: v["data"] for k, v in o.items()}
    if o.get("is_default"):
        print(o["id"])
        break
')"
if [ -z "$default_input" ]; then
    echo "AUDIO_INPUT_FAIL (ListInputs lists no default microphone; is the VM booted with -Audio? wpctl status above shows the sources)"
else
    echo "default microphone: $default_input"
    unknown="$(dev_call SetInput s "no-such-microphone")"
    sink_name="$(default_node)"
    refused_sink="$(dev_call SetInput s "$sink_name")"
    same="$(dev_call SetInput s "$default_input")"
    echo "SetInput unknown -> $unknown; SetInput <the default sink's name> -> $refused_sink; SetInput <the default> -> $same"
    before="$(dev_prop get-property)"
    dev_prop set-property b true >/dev/null
    sleep 1
    muted_pw="$(src_mute_of)"
    muted_bus="$(dev_prop get-property)"
    dev_prop set-property b false >/dev/null
    sleep 1
    unmuted_pw="$(src_mute_of)"
    unmuted_bus="$(dev_prop get-property)"
    echo "InputMuted before=$before; after set true: bus=$muted_bus wpctl-muted=$muted_pw; after set false: bus=$unmuted_bus wpctl-muted=$unmuted_pw"
    if [ "$unknown" = 's "unknown-input"' ] && [ "$refused_sink" = 's "unknown-input"' ] && [ "$same" = 's "ok"' ] \
        && [ "$muted_bus" = "b true" ] && [ "$muted_pw" = true ] && [ "$unmuted_bus" = "b false" ] && [ "$unmuted_pw" = false ]; then
        echo "AUDIO_INPUT_OK"
    else
        echo "AUDIO_INPUT_FAIL"
    fi
fi
