#!/usr/bin/env bash
# Captures what the kernel knows about the connected screens, in the layout of /sys/class/drm, so that
# the display service can be tried on any machine (T-198). Run it on the console (SSH or a shell) of
# the machine whose TV or monitor is to be looked at:
#   bash display-capture.sh [outdir]            # default: ./display-capture
# then copy the directory (or the .tar.gz next to it) to the development host and read it with
#   ruya-devices --display-list <outdir>        # the outputs and modes the service would offer
#   RUYA_DRM_DIR=<outdir> ruya-devices --session   # or serve them on the session bus for the shell
# Only connected connectors are captured; `status`, `modes` and `edid` (binary) are what the service
# reads, `enabled` and `dpms` are for the notes. The EDID has the monitor's name, its physical size
# and its serial number: it is hardware identity, not a secret, but look before sharing it publicly.
set -eu
out="${1:-display-capture}"
mkdir -p "$out"
n=0
for c in /sys/class/drm/card*-*; do
    [ -d "$c" ] || continue
    name="$(basename "$c")"
    [ "$(cat "$c/status" 2>/dev/null)" = connected ] || { echo "skip $name ($(cat "$c/status" 2>/dev/null))"; continue; }
    mkdir -p "$out/$name"
    for f in status modes enabled dpms; do
        [ -r "$c/$f" ] && cp "$c/$f" "$out/$name/$f"
    done
    [ -r "$c/edid" ] && cp "$c/edid" "$out/$name/edid"
    echo "captured $name: $(wc -l <"$out/$name/modes") mode lines, edid $(wc -c <"$out/$name/edid" 2>/dev/null || echo 0) bytes"
    n=$((n + 1))
done
{
    echo "captured: $(date -u +%FT%TZ) on $(uname -srm)"
    echo "gpu: $(for g in /sys/class/drm/card?/device; do echo "$(basename "$(dirname "$g")") $(basename "$(readlink -f "$g/driver" 2>/dev/null)")"; done | tr '\n' ';')"
    command -v edid-decode >/dev/null 2>&1 && echo "edid-decode: available (run it on each edid file for the full picture)"
} >"$out/NOTES.txt"
tar -czf "$out.tar.gz" -C "$(dirname "$out")" "$(basename "$out")"
echo "$n connected output(s) captured in $out and $out.tar.gz"
