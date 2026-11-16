#!/usr/bin/env bash
# Q2: a Windows game under Wine inside a generated play.* sandbox, launched
# like a game through org.ruyaos.Session1.Launch on the profile's Wayland socket.
#   q2-wine.sh build            build play.test.winewl (sockets=wayland, Wine's
#                               winewayland driver) and play.test.winex11
#                               (sockets=x11: Session1 runs it through the ADR-034
#                               xwayland-satellite helper)
#   q2-wine.sh run <wl|x11> [s] launch it as the signed-in profile, capture the TV
#                               after [s] seconds (default 25), print the log, stop
# Wine is Flathub's org.winehq.Wine//stable-25.08 copied (hardlinked) to /app,
# the game is Bugdom 1.3.4 for Windows x64 (jorio/Bugdom GitHub release, SDL2 +
# OpenGL, gamepad support). Needs dl/ and x/bugdom from the README's fetch step.
. "$(dirname "$0")/common.sh"
WINE_FILES=/var/lib/flatpak/app/org.winehq.Wine/current/active/files
GAME=$WORK/x/bugdom

# Wine's own 32-bit and GL extension points (its build is the old WoW64 layout:
# i386-unix needs the 32-bit runtime), copied from org.winehq.Wine's metadata.
WINE_EXT=(
    --allow=multiarch
    --extension=org.freedesktop.Platform.Compat.i386=directory=lib/i386-linux-gnu
    --extension=org.freedesktop.Platform.Compat.i386=version=25.08
    --extension=org.freedesktop.Platform.GL32=directory=lib/i386-linux-gnu/GL
    --extension=org.freedesktop.Platform.GL32=version=1.4
    --extension=org.freedesktop.Platform.GL32=versions=25.08\;1.4
    --extension=org.freedesktop.Platform.GL32=subdirectories=true
    --extension=org.freedesktop.Platform.GL32=add-ld-path=lib
    --extension=org.freedesktop.Platform.GL32=merge-dirs=vulkan/icd.d\;glvnd/egl_vendor.d\;egl/egl_external_platform.d\;OpenCL/vendors\;lib/dri\;lib/d3d\;lib/gbm\;vulkan/explicit_layer.d\;vulkan/implicit_layer.d
)

manifest() {   # manifest <wayland|x11>
    cat <<EOF
{ "id": "test.wine$1",
  "run": {
    "setup": [["wine", "reg", "add", "HKCU\\\\Software\\\\Wine\\\\Drivers", "/v", "Graphics", "/d", "$1", "/f"]],
    "command": ["wine", "\${payload}/Bugdom.exe"],
    "env": { "WINEPREFIX": "\${prefix}", "WINEDEBUG": "fps,err+all,fixme-all", "WINEDLLOVERRIDES": "mscoree,mshtml=" } } }
EOF
}

case ${1:-} in
build)
    [ -d "$WINE_FILES" ] || { echo "install org.winehq.Wine//stable-25.08 first"; exit 1; }
    ensure_remote
    flatpak list --system --columns=ref | grep -q Play.Launcher || { build_launcher; install_ref org.ruyaos.Play.Launcher; }
    manifest wayland > "$WORK/src/winewl.play.json"
    manifest x11 > "$WORK/src/winex11.play.json"
    t=$(now)
    APP_ROOT_FROM=$WINE_FILES build_app play.test.winewl "$GAME" "$WORK/src/winewl.play.json" \
        --socket=wayland --socket=pulseaudio --device=all --share=ipc "${WINE_EXT[@]}"
    APP_ROOT_FROM=$WINE_FILES build_app play.test.winex11 "$GAME" "$WORK/src/winex11.play.json" \
        --socket=x11 --socket=pulseaudio --device=all --share=ipc "${WINE_EXT[@]}"
    log "both exported in $(elapsed "$t") s"
    t=$(now); du0=$(du -sm /var/lib/flatpak | cut -f1)
    install_ref play.test.winewl play.test.winex11
    log "installed in $(elapsed "$t") s, /var/lib/flatpak +$(( $(du -sm /var/lib/flatpak | cut -f1) - du0 )) MiB (Wine objects shared with org.winehq.Wine?)"
    ;;
run)
    v=${2:?wl or x11}; wait=${3:-25}; id=play.test.wine$v
    p=${PROFILE:-p1}; u=ruya-$p
    since=$(date '+%F %T')
    busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss "$id" "$p"
    sleep "$wait"
    mkdir -p "$WORK/shots"
    ffmpeg -hide_banner -loglevel error -y -device /dev/dri/card1 -f kmsgrab -i - \
        -vf 'hwmap=derive_device=vaapi,scale_vaapi=w=960:h=540:format=nv12,hwdownload,format=nv12' \
        -frames:v 1 "$WORK/shots/$id.png" && echo "capture: $WORK/shots/$id.png"
    busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning
    pid=$(pgrep -u "$u" -f 'Bugdom.exe' | head -1)
    [ -n "$pid" ] && grep -E 'VmRSS|Threads' "/proc/$pid/status"
    pgrep -u "$u" -a -f 'xwayland-satellite|Xwayland' || true
    journalctl --no-pager -q --since="$since" _UID="$(id -u "$u")" | grep -v -E 'fixme:' | tail -${LINES_SHOWN:-40}
    systemctl --user -M "$u@.host" list-units --plain --no-legend "app-flatpak-$id-*" "ruya-app-$u-$id*"
    [ -n "${KEEP:-}" ] || busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 \
        Stop s "ruya-app-$u-$id.service"
    ;;
*) sed -n 2,12p "$0"; exit 2 ;;
esac
