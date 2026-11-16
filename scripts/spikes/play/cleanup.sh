#!/usr/bin/env bash
# Remove everything the spike installed or wrote on the test machine, except the
# downloads and Flathub refs that are slow to fetch again (KEEP_FETCHED=1, the
# default): $WORK/dl, $WORK/x (GE-Proton, umu, Bugdom), org.winehq.Wine//stable-25.08
# and org.freedesktop.Sdk//25.08. KEEP_FETCHED=0 removes those too.
. "$(dirname "$0")/common.sh"
set +e
apps=$(flatpak list --system --columns=application | grep -E '^play\.test\.')
[ -z "$apps" ] || flatpak uninstall -y --system --noninteractive $apps
flatpak uninstall -y --system --noninteractive org.ruyaos.Play.Launcher
for r in ruy91-local ruy91-size; do flatpak remote-delete --system --force "$r" 2>/dev/null; done
for h in /var/home/ruya-*; do rm -rf "$h"/.var/app/play.test.*; done
rm -rf "$WORK"/repo* "$WORK/build" "$WORK/src" "$WORK/gnupg" "$WORK/key.id" "$WORK/key.gpg" "$WORK/x/umusrc"
if [ "${KEEP_FETCHED:-1}" = 0 ]; then
    flatpak uninstall -y --system --noninteractive org.winehq.Wine//stable-25.08 org.freedesktop.Sdk//25.08
    flatpak uninstall -y --system --noninteractive --unused
    rm -rf "$WORK"
fi
flatpak list --system --columns=ref | grep -i -E 'play|wine|Sdk' || true
du -sh "$WORK" 2>/dev/null
df -h /var | tail -1
