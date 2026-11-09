#!/usr/bin/env bash
# The saved output survives a reboot (T-360). Two steps around a reboot, run as root in the VM
# (vm-reboot-check.ps1 -SavedOutput copies and runs this file):
#   vm-saved-output-check.sh choose   picks an output (a non-default usable one when there is one,
#                                     else the default), calls SetOutput, remembers its id
#   vm-saved-output-check.sh verify   after the reboot: that output must be the default again
# Prints AUDIO_REBOOT_SAVED_OUTPUT_OK or AUDIO_REBOOT_SAVED_OUTPUT_FAIL (reason); exit 0 / 1.
set -u
mode="${1:-}"
keep=/root/saved-output-id
list() {
    busctl --system --json=short call org.ruyaos.Devices1 /org/ruyaos/Devices1 \
        org.ruyaos.Devices1.Audio ListOutputs 2>/dev/null
}
# Prints "<id> <is_default> <available>" per output row.
rows() {
    list | python3 -c '
import json, sys
for o in json.load(sys.stdin)["data"][0]:
    o = {k: v["data"] for k, v in o.items()}
    print(o["id"], str(o["is_default"]).lower(), o.get("available", ""))
'
}
case "$mode" in
choose)
    pick="$(rows | awk '$3 != "no" && $2 == "false" {print $1; exit}')"
    [ -n "$pick" ] || pick="$(rows | awk '$2 == "true" {print $1; exit}')"
    if [ -z "$pick" ]; then echo "AUDIO_REBOOT_SAVED_OUTPUT_FAIL (no output listed)"; exit 1; fi
    status="$(busctl --system call org.ruyaos.Devices1 /org/ruyaos/Devices1 org.ruyaos.Devices1.Audio SetOutput s "$pick" 2>&1)"
    echo "SetOutput $pick -> $status"
    case "$status" in
    *'"ok"'*) echo "$pick" > "$keep"; echo "chosen $pick (waiting 12 s for WirePlumber to save its state)"; sleep 12 ;;
    *) echo "AUDIO_REBOOT_SAVED_OUTPUT_FAIL (SetOutput refused)"; exit 1 ;;
    esac
    ;;
verify)
    want="$(cat "$keep" 2>/dev/null)"
    [ -n "$want" ] || { echo "AUDIO_REBOOT_SAVED_OUTPUT_FAIL (no remembered id; run choose first)"; exit 1; }
    # ruya-devices may start before WirePlumber: give the late policy a few seconds.
    for _ in $(seq 1 30); do
        got="$(rows | awk '$2 == "true" {print $1; exit}')"
        [ "$got" = "$want" ] && break
        sleep 1
    done
    if [ "$got" = "$want" ]; then echo "AUDIO_REBOOT_SAVED_OUTPUT_OK ($got is the default after the reboot)"; exit 0; fi
    echo "AUDIO_REBOOT_SAVED_OUTPUT_FAIL (default is '${got:-none}', wanted $want)"
    exit 1
    ;;
*) echo "usage: $0 choose|verify"; exit 2 ;;
esac
