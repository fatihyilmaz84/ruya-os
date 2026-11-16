#!/usr/bin/env bash
# Q3: a bundled GE-Proton started through umu-launcher and the Steam Linux
# Runtime (pressure-vessel) inside a generated play.* sandbox.
#   q3-proton.sh build          play.test.proton: /app/components/proton (GE-Proton11-12),
#                               /app/components/umu (umu-launcher 1.4.4 zipapp),
#                               /app/payload (Bugdom for Windows). Default command:
#                               umu-run (which fetches the SLR it needs on first run)
#   q3-proton.sh launch [s]     through Session1.Launch as the signed-in profile
#   q3-proton.sh umu [args]     umu-run in the sandbox as the profile, portal allowed
#   q3-proton.sh umu-noportal   the same without a session bus (--no-talk-name does not block the portal)
#   q3-proton.sh direct         GE-Proton's own 'proton' script, no SLR, no umu
#   q3-proton.sh portal         is org.freedesktop.portal.Flatpak reachable (flatpak-spawn --sandbox)
. "$(dirname "$0")/common.sh"
ID=${ID:-play.test.proton}
P=${PROFILE:-p1}; U=ruya-$P
PROTON=$WORK/x/GE-Proton11-12-x86_64
COMMON_ENV=(--env=PROTONPATH=/app/components/proton --env=GAMEID=umu-default
    --env=STORE=none --env=UMU_LOG=debug --env=PROTON_ENABLE_WAYLAND=1
    --env=WINEPREFIX=/var/data/prefix-umu)

case ${1:-} in
build)
    ensure_remote
    cat > "$WORK/src/proton.play.json" <<'EOF'
{ "id": "test.proton",
  "run": { "command": ["${component:umu}/umu-run", "${payload}/Bugdom.exe"],
           "env": { "PROTONPATH": "${component:proton}", "GAMEID": "umu-default", "STORE": "none",
                    "WINEPREFIX": "${prefix}", "PROTON_ENABLE_WAYLAND": "1", "UMU_LOG": "debug" } } }
EOF
    t=$(now)
    COMPONENTS="proton=$PROTON umu=$WORK/x/umu" build_app "$ID" "$WORK/x/bugdom" "$WORK/src/proton.play.json" \
        --socket=wayland --socket=pulseaudio --device=all --share=ipc --share=network --allow=multiarch \
        --extension=org.freedesktop.Platform.Compat.i386=directory=lib/i386-linux-gnu \
        --extension=org.freedesktop.Platform.Compat.i386=version=25.08 \
        --extension=org.freedesktop.Platform.GL32=directory=lib/i386-linux-gnu/GL \
        --extension=org.freedesktop.Platform.GL32=version=1.4 \
        --extension=org.freedesktop.Platform.GL32=versions=25.08\;1.4 \
        --extension=org.freedesktop.Platform.GL32=subdirectories=true \
        --extension=org.freedesktop.Platform.GL32=add-ld-path=lib \
        --extension=org.freedesktop.Platform.GL32=merge-dirs=vulkan/icd.d\;glvnd/egl_vendor.d\;egl/egl_external_platform.d\;lib/dri\;lib/gbm\;vulkan/explicit_layer.d\;vulkan/implicit_layer.d
    log "exported in $(elapsed "$t") s"
    t=$(now); install_ref "$ID"; log "installed in $(elapsed "$t") s"
    ;;
build-x11)
    # play.test.protonx11: the fallback, GE-Proton's own 'proton' script with no
    # SLR and no umu, sockets=x11 so Session1 runs it through xwayland-satellite.
    ensure_remote
    cat > "$WORK/src/protonx11.play.json" <<'EOF'
{ "id": "test.protonx11",
  "run": { "setup": [["mkdir", "-p", "${data}/compat", "${data}/steam"]],
           "command": ["python3", "${component:proton}/proton", "waitforexitandrun", "${payload}/Bugdom.exe"],
           "env": { "STEAM_COMPAT_DATA_PATH": "${data}/compat", "STEAM_COMPAT_CLIENT_INSTALL_PATH": "${data}/steam",
                    "SteamGameId": "0", "SteamAppId": "0", "PROTON_LOG": "1", "PROTON_LOG_DIR": "${data}" } } }
EOF
    t=$(now)
    COMPONENTS="proton=$PROTON" build_app play.test.protonx11 "$WORK/x/bugdom" "$WORK/src/protonx11.play.json" \
        --socket=x11 --socket=pulseaudio --device=all --share=ipc --allow=multiarch \
        --extension=org.freedesktop.Platform.Compat.i386=directory=lib/i386-linux-gnu \
        --extension=org.freedesktop.Platform.Compat.i386=version=25.08 \
        --extension=org.freedesktop.Platform.GL32=directory=lib/i386-linux-gnu/GL \
        --extension=org.freedesktop.Platform.GL32=version=1.4 \
        --extension=org.freedesktop.Platform.GL32=versions=25.08\;1.4 \
        --extension=org.freedesktop.Platform.GL32=subdirectories=true \
        --extension=org.freedesktop.Platform.GL32=add-ld-path=lib \
        --extension=org.freedesktop.Platform.GL32=merge-dirs=vulkan/icd.d\;glvnd/egl_vendor.d\;egl/egl_external_platform.d\;lib/dri\;lib/gbm\;vulkan/explicit_layer.d\;vulkan/implicit_layer.d
    log "exported in $(elapsed "$t") s"
    t=$(now); install_ref play.test.protonx11; log "installed in $(elapsed "$t") s"
    ;;
launch)
    since=$(date '+%F %T')
    busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss "$ID" "$P"
    sleep "${2:-40}"
    busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning
    journalctl --no-pager -q --since="$since" _UID="$(id -u "$U")" | grep -v 'fixme:' | tail -${LINES_SHOWN:-60}
    [ -n "${KEEP:-}" ] || busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 \
        Stop s "ruya-app-$U-$ID.service"
    ;;
umu)
    shift; t=$(now)
    prun "$P" timeout "${TIMEOUT:-300}" flatpak run "${COMMON_ENV[@]}" ${EXTRA:-} \
        --command=/app/components/umu/umu-run "$ID" "${@:-/app/payload/Bugdom.exe}" || echo "rc=$?"
    log "umu run ended after $(elapsed "$t") s"
    ;;
umu-noportal)
    shift; EXTRA="${EXTRA:-} --no-session-bus" bash "$0" umu "$@"
    ;;
direct)
    shift; t=$(now)
    prun "$P" timeout "${TIMEOUT:-120}" flatpak run --env=STEAM_COMPAT_DATA_PATH=/var/data/compat-direct \
        --env=STEAM_COMPAT_CLIENT_INSTALL_PATH=/var/data/steam --env=PROTON_ENABLE_WAYLAND=1 \
        --env=PROTON_LOG=1 --env=PROTON_LOG_DIR=/var/data --env=SteamGameId=0 --env=SteamAppId=0 ${EXTRA:-} \
        --command=sh "$ID" -c 'mkdir -p /var/data/compat-direct /var/data/steam && exec python3 /app/components/proton/proton waitforexitandrun "$@"' \
        sh "${@:-/app/payload/Bugdom.exe}" || echo "rc=$?"
    log "direct proton ended after $(elapsed "$t") s"
    ;;
portal)
    prun "$P" flatpak run ${EXTRA:-} --command=sh "$ID" -c \
        'echo "container=$container"; time flatpak-spawn --sandbox --watch-bus sh -c "echo sub-sandbox ok: \$(id -u) \$FLATPAK_ID; cat /.flatpak-info | head -3"' 2>&1
    ;;
*) sed -n 2,13p "$0"; exit 2 ;;
esac
