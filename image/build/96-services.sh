#!/usr/bin/env bash
# Services that stay installed but are not wanted (T-195). Runs after image/rootfs is copied, so
# the preset file in /usr/lib/systemd/system-preset/45-ruyaos.preset exists. The preset file says
# what is disabled; `systemctl preset` removes the enablement links Fedora's packages made.
set -euo pipefail
preset=/usr/lib/systemd/system-preset/45-ruyaos.preset
test -f "$preset"

while read -r verb unit; do
    [ "$verb" = disable ] || continue
    if systemctl cat "$unit" >/dev/null 2>&1; then
        systemctl preset "$unit"
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            echo "96-services: $unit is still enabled after preset"
            exit 1
        fi
    else
        echo "96-services: $unit does not exist (package removed): skipped"
    fi
done <"$preset"

# Fedora's OCI remote is not wanted: ruya-flathub-remote.service adds Flathub and deletes `fedora`
# (03 §6). The stock unit would add `fedora` again on the first boot.
MASKED="flatpak-add-fedora-repos.service"
for unit in $MASKED; do
    systemctl mask "$unit"
done
