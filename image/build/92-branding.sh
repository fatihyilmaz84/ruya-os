#!/usr/bin/env bash
# Name the OS RuyaOS in os-release: the boot menu entries (and `hostnamectl`, `bootc status`
# tooling that prints PRETTY_NAME) show it. ID, VERSION_ID and ID_LIKE stay as Fedora ships them,
# because bootc-image-builder, Anaconda, Flatpak and the akmods step key on those.
set -euo pipefail
version="$(cat /usr/lib/ruyaos/version)"
f=/usr/lib/os-release
sed -i -e 's/^NAME=.*/NAME="RuyaOS"/' \
       -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"RuyaOS ${version}\"/" "$f"
grep -qx 'NAME="RuyaOS"' "$f"
grep -qx "PRETTY_NAME=\"RuyaOS ${version}\"" "$f"
grep -qx 'ID=fedora' "$f"
echo "92-branding: $(grep '^PRETTY_NAME=' "$f")"
