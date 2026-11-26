#!/usr/bin/env bash
# modes: check newest steam sample
# needs: profile check sample
# (check and sample run a Windows program on an X display of the signed-in profile, RUY-980; vm-queue.ps1 reads this line)
# Checks the Play platform on /usr (ADR-038, RUY-34) inside a running VM, as root, offline:
#   1. links: every L+ line of /usr/lib/tmpfiles.d/ruya-play-platform.conf is a link under
#      /var/lib/flatpak/extension to its folder on /usr, and that folder is there
#   2. launcher: /usr/lib/ruyaos/play/launcher/bin/ruya-play-launch is executable and, started
#      outside a sandbox, refuses with its own sentence (no /app/play.files): the static binary runs
#   3. runners: for each folder of /usr/lib/ruyaos/play/runners, ruya-pack runner-check (the
#      format's parser and runner hash) accepts its runner.json and computes the hash the image
#      wrote into .ruya-runner-hash (Library1 ListRunners, which the About pane reads, is
#      vm-library-check.sh runners, RUY-959), and its i386 ntdll.dll is labelled textrel_shlib_t
#      (ls -Z; the image's ruya_play_runners module, RUY-999: Wine's execmod of a lib_t DLL is denied)
#   4. a Windows program runs through each Proton and each Wine runner as a profile user, without
#      network: a Proton runner's own cmd.exe through `proton waitforexitandrun` (ADR-037's argv,
#      the STEAM_COMPAT_* folders in a scratch data folder, SteamAppId and SteamGameId 0, PWD: what
#      ruya-play-launch sets, RUY-969), and a Wine runner's own 64-bit and
#      32-bit cmd.exe through its runner.json `entry.wine` (WINEPREFIX in a scratch folder, Mono
#      and Gecko off: the image ships neither) each print a marker, under `unshare -n`.
#      Proton needs an X display (it gives every program a console window, which hangs without one), so
#      its program runs on the display a launch gets: through `ruya-session x11-run` as the profile user
#      (run_on_display), and cmd.exe writes the marker to a file the check reads, because that console
#      window, not stdout, gets what cmd.exe echoes (RUY-980). It runs as the signed-in profile
#      (Profiles1 ActiveProfile). With nobody signed in the step is a SKIP with its reason (the check
#      signs in none; vm-queue.ps1 does it with vm-goto.ps1 home); x11-run starting no X server for the
#      signed-in profile, a helper missing from the image, or a helper that did not run `flatpak` from the
#      PATH is a FAIL.
# Mode `steam` (RUY-35, after the Steam Flatpak is installed and was started once as a profile):
#   5. every Proton runner is linked into Steam's extension point
#      (com.valvesoftware.Steam.CompatibilityTool.<Name>/x86_64/stable) and carries its
#      compatibilitytool.vdf, so Steam lists the tool
#   6. the Steam Flatpak is installed, and in each profile that started Steam, Steam's own files
#      (steam.sh or ubuntu12_32) are in the root that holds config.vdf, and the default
#      compatibility tool (CompatToolMapping "0") is the newest Proton runner's tool (newest by
#      runner.json version): anything else FAILs, so it catches Steam replacing our entry on its
#      first run and a wrong config path
# Mode `sample` (RUY-36, samples/hello-runner/run-windows.py copied to the guest by vm-queue.ps1):
#   7. the developer guide's sample script (docs/developers/windows-games.md) runs against the image's own
#      runners, as a profile user under `unshare -n`: it reads their runner.json, takes a Proton runner of
#      the image, starts the runner's cmd.exe through `proton waitforexitandrun` and prints its marker, and
#      the Proton prefix is made in the profile's data folder. This is the script, not the Flatpak: the
#      mount of an app's extension point is vm-play-check.sh's; building the sample with flatpak-builder in
#      the VM is not done. The script runs as the signed-in profile on the same display as in `check`, and
#      with nobody signed in the step is a SKIP, as there; a missing display is a FAIL.
# Running a game inside a .play sandbox (the extension mounts, the 32-bit points) is
# vm-play-check.sh launch and launch-windows (RUY-902).
# Mode `newest` (RUY-902; `newest <runners dir> <key>=<value>`, no root needed): prints the folder of the newest
# runner.json whose key is the value (kind=proton, family=proton-ge) by the numbers in its version. `steam`
# uses it and so does vm-play-check.sh (its launch-windows names the system runner the status file records):
# the one copy of that rule on the VM side.
#
# ruya-pack: the Linux build of services/ruya-pack (scripts/ci-samples-linux.sh leaves it in
# services/target-samples/release/):
#   scp -P 2222 services/target-samples/release/ruya-pack scripts/vm-runner-check.sh root@127.0.0.1:/root/
#   ssh -p 2222 root@127.0.0.1 bash /root/vm-runner-check.sh check /root/ruya-pack
# and for `sample`, the script next to it (vm-queue.ps1 copies it with the others):
#   scp -P 2222 samples/hello-runner/run-windows.py root@127.0.0.1:/root/
#   ssh -p 2222 root@127.0.0.1 bash /root/vm-runner-check.sh sample /root/run-windows.py
# Host fixtures (scripts/test-vm-checks.sh): RUYA_ROOT=<dir> puts every path the check reads below
# <dir>; the link targets in the tmpfiles file stay as written. JSON is parsed by key.
set -u
mode="${1:-check}"
pack="${2:-/root/ruya-pack}"
root="${RUYA_ROOT:-}"
conf="$root/usr/lib/tmpfiles.d/ruya-play-platform.conf"
play="$root/usr/lib/ruyaos/play"
launcher="$play/launcher/bin/ruya-play-launch"
# The helper that starts the X server of a launch (ADR-034) and the profiles' Wayland sockets it connects to.
session="$root/usr/bin/ruya-session"
wayland_dir=/run/ruya-wayland
marker=RUYA_RUNNER_OK
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
# The id of the profile that is signed in ("p1": Profiles1's ActiveProfile), or nothing. x11-run's X server
# connects to the signed-in profile's Wayland socket, so a program that needs a display runs as that one.
active_profile() {
    busctl --system get-property org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ActiveProfile 2>/dev/null | cut -d'"' -f2
}

# newest_runner <runners dir> <key>=<value>: the folder name of the newest runner.json one folder below <dir>
# whose <key> is <value> (kind=proton, family=proton-ge), nothing and exit 1 when none. "Newest" is the
# rule of resolve::compare_versions: the numbers in the version, compared in order (GE-Proton11-13 is 11, 12).
# The one copy: `steam` uses it, and vm-play-check.sh asks for it through the `newest` mode.
newest_runner() {
    python3 -I - "$1" "$2" <<'PYEOF'
import json, os, re, sys
key, _, want = sys.argv[2].partition("=")
best = None
for name in sorted(os.listdir(sys.argv[1])):
    try:
        with open(os.path.join(sys.argv[1], name, "runner.json"), encoding="utf-8") as f:
            r = json.load(f)
    except (OSError, ValueError):
        continue
    if r.get(key) != want:
        continue
    k = [int(n) for n in re.findall(r"[0-9]+", str(r.get("version", "")))]
    if best is None or k > best[0]:
        best = (k, name)
if best is None:
    sys.exit(1)
print(best[1])
PYEOF
}

# win_path <file>: the Windows name of a file for the Proton prefix, whose Z: drive is the root of the file system.
win_path() {
    printf 'Z:%s' "$1" | tr / '\\'
}

# run_on_display <user> <data> [VAR=value ...] -- <command> [args...]: runs the command as <user>, under
# `unshare -n`, on an X display made the way a launch makes it (RUY-980): through `ruya-session x11-run`, the
# helper that starts xwayland-satellite for the signed-in profile and runs `flatpak run <app id>` on it
# (DISPLAY, XAUTHORITY, no WAYLAND_DISPLAY; 05 §6.3). The helper runs nothing but `flatpak`, so a `flatpak`
# in front of PATH is the command: it notes the display in <data>/display and execs the command. The one
# assumption of this seam: x11-run starts `flatpak` by name through the PATH it was given (x11::app_argv),
# not as /usr/bin/flatpak; if that changes, x11_failed says so. Proton
# opens a console window for every program (CREATE_NEW_CONSOLE) and without a display waits for ever, so a
# program that needs none (cmd.exe's echo) still needs this. The helper's XDG_RUNTIME_DIR is <data>/run
# (Wine wants one it may use; the profile's own may not be there). The VAR=value are the program's
# environment. Output: the helper's log and the command's; status: the command's. No <data>/display
# afterwards means the command never ran: the caller reports it with x11_failed (a FAIL, never a SKIP: the
# user is the signed-in profile).
run_on_display() {
    local user="$1" data="$2"; shift 2
    local vars=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    mkdir -p "$data/bin" "$data/run"
    chmod 700 "$data/run"
    {
        echo '#!/bin/bash'
        echo 'printf %s "$DISPLAY" > "$RUYA_DISPLAY_FILE"'
        printf 'exec'; printf ' %q' "$@"; echo
    } > "$data/bin/flatpak"
    chmod +x "$data/bin/flatpak"
    chown -R "$user" "$data"
    (cd "$data" && unshare -n runuser -u "$user" -- env -i HOME="$data" PATH="$data/bin:$PATH" \
        XDG_RUNTIME_DIR="$data/run" WAYLAND_DISPLAY="$wayland_dir/$user" RUYA_DISPLAY_FILE="$data/display" \
        "${vars[@]}" "$session" x11-run org.ruyaos.RunnerCheck 2>&1)
}

# x11_failed <user> <what> <output>: the FAIL for a program that run_on_display did not run (no <data>/display):
# the helper is not on the image, or it started the X server but did not run `flatpak` from the PATH, or the
# signed-in profile got no X server.
x11_failed() {
    local tail_
    tail_="$(printf '%s' "$3" | tail -n 3 | tr '\n' ' ')"
    if [ ! -x "$session" ]; then
        bad "$session is missing: the image has no ruya-session x11-run helper, so $2 was not run"
    elif printf '%s' "$3" | grep -q 'runs on display'; then
        bad "x11-run started an X server for $1 but did not run flatpak from PATH, so $2 was not run (the seam of run_on_display no longer holds); the helper said: $tail_"
    else
        bad "the signed-in profile $1 got no X server from ruya-session x11-run, so $2 was not run (Proton cannot run a program without a display); the helper said: $tail_"
    fi
}

if [ "$mode" = newest ]; then
    newest_runner "${2:?runners dir}" "${3:?key=value}"
    exit $?
fi

[ "$mode" = check ] || [ "$mode" = steam ] || [ "$mode" = sample ] || { echo "usage: vm-runner-check.sh [check|steam|sample] [ruya-pack | run-windows.py] | newest <runners dir> <key>=<value>"; exit 2; }

if [ "$mode" = sample ]; then
    script="${2:-/root/run-windows.py}"
    echo "--- the sample script runs a Windows program through the image's runner, offline, as a profile user"
    profile="$(active_profile)"
    if [ ! -f "$script" ]; then
        bad "$script (samples/hello-runner/run-windows.py) is not on the guest"
    elif [ -z "$profile" ]; then
        echo "SKIP: no profile is signed in: the sample was not run (sign one in first, vm-goto.ps1 home; this check signs in none)"
    else
        user="ruya-$profile"
        data="$(mktemp -d "$root/var/tmp/ruya-runner-sample.XXXXXX")" || { bad "no scratch folder in /var/tmp"; data=""; }
        if [ -n "$data" ]; then
            # /root is closed to the profile user: run a copy of the script from the scratch folder.
            cp "$script" "$data/run-windows.py"
            chown -R "$user" "$data"
            # XDG_DATA_HOME is the app's data folder as a sandbox sets it; the script puts Proton's prefix below it.
            # Started from the scratch folder: the script sets PWD from its working folder, which must be one the
            # profile user can use (a console launcher gives the game /app/payload).
            # The script needs a display (Proton opens a console window) and reads the marker from a file cmd.exe
            # writes, then prints it itself (RUY-980): run_on_display gives it the display a launch gets.
            out="$(run_on_display "$user" "$data" XDG_DATA_HOME="$data/xdg" WINEDEBUG=-all -- \
                timeout 300 python3 "$data/run-windows.py" --runners "$play/runners" --self-test)"; rc=$?
            used="$(printf '%s\n' "$out" | sed -n 's/^hello-runner: using \([^ ]*\) (.*/\1/p' | head -1)"
            if [ ! -s "$data/display" ]; then
                x11_failed "$user" "the sample" "$out"
            else
                if [ -n "$used" ] && [ -f "$play/runners/$used/runner.json" ]; then ok "the script took the runner $used from $play/runners"; else bad "the script named no runner of the image: '$used'"; fi
                if [ "$rc" = 0 ] && printf '%s\n' "$out" | tr -d '\r' | grep -qx RUYA_HELLO_RUNNER_OK; then
                    ok "${used:-the runner}: cmd.exe printed RUYA_HELLO_RUNNER_OK as $user without network, on display $(cat "$data/display")"
                else
                    bad "the sample as $user: exit $rc; last lines: $(printf '%s' "$out" | tail -n 5 | tr '\n' ' ')"
                fi
                if [ -d "$data/xdg/proton/pfx" ]; then ok "the Proton prefix is in the app's data folder (\$XDG_DATA_HOME/proton/pfx)"; else bad "no Proton prefix at \$XDG_DATA_HOME/proton/pfx"; fi
            fi
            [ -n "$used" ] && runuser -u "$user" -- env WINEPREFIX="$data/xdg/proton/pfx" "$play/runners/$used/files/bin/wineserver" -k >/dev/null 2>&1
            rm -rf "$data"
        fi
    fi
    [ "$fail" = 0 ] && echo "vm-runner-check: all passed" || echo "vm-runner-check: FAILED"
    exit "$fail"
fi

if [ "$mode" = steam ]; then
    steam_ext="$root/var/lib/flatpak/extension"
    echo "--- Steam sees the runners"
    # The newest Proton runner by its runner.json version (the rule of resolve::compare_versions:
    # the numbers in the version, compared in order) and its tool name through Steam's link.
    newest="$(newest_runner "$play/runners" kind=proton)"
    want=""
    for tree in "$play"/runners/*/; do
        name="$(basename "$tree")"
        [ -f "$tree/compatibilitytool.vdf" ] || continue
        link="$steam_ext/com.valvesoftware.Steam.CompatibilityTool.$name/x86_64/stable"
        tool="$(grep -A3 '"compat_tools"' "$link/compatibilitytool.vdf" 2>/dev/null | grep -o '"[^"]*"' | sed -n 2p | tr -d '"')"
        if [ -n "$tool" ]; then ok "$name: Steam's extension point has the tool $tool"; [ "$name" = "$newest" ] && want="$tool"; else bad "$name: no compatibilitytool.vdf through $link"; fi
    done
    [ -n "$want" ] && ok "the newest Proton runner is $newest, tool $want" || bad "no tool for the newest Proton runner '${newest:-none}'"
    echo "--- the default tool of each profile that started Steam"
    if [ -d "$root/var/lib/flatpak/app/com.valvesoftware.Steam" ]; then ok "the Steam Flatpak is installed"; else bad "the Steam Flatpak is not installed (install it from the Store first)"; fi
    seen=0
    while IFS=: read -r user _ _ _ _ home _; do
        case "$user" in ruya-p*) ;; *) continue ;; esac
        steamdir="$root$home/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        cfg="$steamdir/config/config.vdf"
        [ -f "$cfg" ] || continue
        seen=$((seen + 1))
        # Steam's own files in the same root prove Steam ran there and kept (or wrote) this config,
        # not only that our step wrote it.
        if [ -e "$steamdir/steam.sh" ] || [ -e "$steamdir/ubuntu12_32" ]; then
            ok "$user: Steam's own files are in $steamdir"
        else
            bad "$user: no steam.sh or ubuntu12_32 in $steamdir: Steam has not run there, or the path is not Steam's"
            continue
        fi
        # The entry "0" of the CompatToolMapping block only (the block is read to its closing brace).
        got="$(awk '
            /"CompatToolMapping"/ { m = 1; d = 0; next }
            m {
                if (index($0, "{")) d++
                else if (index($0, "}")) { d--; if (d <= 0) exit; if (d == 1) z = 0 }
                else if (d == 1 && $1 == "\"0\"") z = 1
                else if (d == 2 && z && $1 == "\"name\"") { n = $2; gsub(/"/, "", n); print n; exit }
            }' "$cfg")"
        if [ "$got" = "$want" ]; then ok "$user: the default is $got, the newest runner's tool"; else bad "$user: the default is '${got:-none}', not $want (Steam replaced our entry, the player chose another, or there is none)"; fi
    done < <(getent passwd)
    [ "$seen" -ge 1 ] && ok "$seen profile(s) with a Steam config" || bad "no profile has started Steam yet (start Steam once, then re-run)"
    [ "$fail" = 0 ] && echo "vm-runner-check: all passed" || echo "vm-runner-check: FAILED"
    exit "$fail"
fi

echo "--- links"
n=0
while read -r type path _ _ _ _ target _; do
    [ "$type" = "L+" ] || continue
    n=$((n + 1))
    got="$(readlink "$root$path" 2>/dev/null)"
    if [ "$got" = "$target" ] && [ -d "$root$target" ]; then
        ok "$path -> $target"
    else
        bad "$path is '${got:-no link}', not a link to the folder $target"
    fi
done < <(grep -v '^[[:space:]]*#' "$conf" 2>/dev/null)
[ "$n" -ge 2 ] && ok "$n links (launcher and runners)" || bad "$conf has $n L+ lines (the launcher's and one per runner wanted)"

echo "--- launcher"
if [ -x "$launcher" ] && [ -f "$launcher" ]; then
    out="$("$launcher" 2>&1 </dev/null)"; rc=$?
    case "$rc:$out" in
    "1:ruya-play-launch: This game's play.files cannot be read"*) ok "the launcher runs and refuses outside a sandbox: $out" ;;
    *) bad "the launcher outside a sandbox: exit $rc, '$out'" ;;
    esac
else
    bad "$launcher is not an executable file"
fi

echo "--- runners"
chmod +x "$pack" 2>/dev/null
protons=""
wines=""
count=0
for tree in "$play"/runners/*/; do
    [ -d "$tree" ] || continue
    tree="${tree%/}"; name="$(basename "$tree")"; count=$((count + 1))
    json="$("$pack" runner-check "$tree" --json 2>/dev/null)"
    read -r okk kind hash version <<<"$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
except ValueError:
    print("bad - - -"); sys.exit()
r = o.get("runner") or {}
print("yes" if o.get("ok") is True else "no", r.get("kind") or "-", o.get("hash") or "-", r.get("version") or "-")
')"
    want="$(tr -d '\n' < "$tree/.ruya-runner-hash" 2>/dev/null)"
    if [ "$okk" = yes ] && [ -n "$want" ] && [ "$hash" = "$want" ]; then
        ok "$name: runner.json accepted ($kind $version), hash $hash as recorded"
    else
        bad "$name: runner-check ok=$okk hash '$hash', .ruya-runner-hash '${want:-none}'"
    fi
    dll="$(find "$tree" -path '*/i386-windows/ntdll.dll' -print -quit 2>/dev/null)"
    if [ -n "$dll" ]; then
        label="$(ls -Z "$dll" 2>/dev/null | awk '{print $1}')"
        case "$label" in *:textrel_shlib_t:*) ok "$name: ${dll#"$tree"/} is labelled $label" ;; *) bad "$name: ${dll#"$tree"/} is labelled '${label:-unknown}', not textrel_shlib_t (Wine's execmod is denied: the ruya_play_runners SELinux module)" ;; esac
    else
        # A Wine or Proton runner without it has nothing to carry the label this check is about: not a silent skip.
        case "$kind" in wine | proton) bad "$name: a $kind runner with no i386-windows/ntdll.dll, so its SELinux label cannot be checked" ;; esac
    fi
    [ "$kind" = proton ] && protons="$protons $tree"
    [ "$kind" = wine ] && wines="$wines $tree"
done
[ "$count" -ge 1 ] && ok "$count runner(s)" || bad "no runner under $play/runners"

echo "--- a Windows program through the runner, offline, as a profile user"
profile="$(active_profile)"
if [ -z "$protons" ]; then
    bad "no Proton runner to run a Windows program through"
elif [ -z "$profile" ]; then
    echo "SKIP: no profile is signed in: no Windows program was run (sign one in first, vm-goto.ps1 home; this check signs in none)"
else
    user="ruya-$profile"
    for tree in $protons; do
        name="$(basename "$tree")"
        exe="$tree/files/lib/wine/x86_64-windows/cmd.exe"
        data="$(mktemp -d "$root/var/tmp/ruya-runner-check.XXXXXX")" || { bad "no scratch folder in /var/tmp"; continue; }
        mkdir -p "$data/proton/client"
        chown -R "$user" "$data"
        # The environment of ruya-play-launch for a Proton game (plan.rs, 05 §6.3): the compat folders, no Steam
        # game id (protonfixes parses one out of the compat path when none is set, and PWD is read unguarded)
        # and PWD = the working folder it starts the game in.
        # On the display a launch gets (run_on_display), and the marker is read from a file cmd.exe writes: Proton
        # starts the program with CREATE_NEW_CONSOLE, so what it echoes goes to a console window, not to stdout
        # (RUY-980).
        out="$(run_on_display "$user" "$data" \
            STEAM_COMPAT_DATA_PATH="$data/proton" STEAM_COMPAT_CLIENT_INSTALL_PATH="$data/proton/client" \
            SteamAppId=0 SteamGameId=0 PWD="$data" WINEDEBUG=-all -- \
            timeout 300 python3 "$tree/proton" waitforexitandrun "$exe" /c "echo $marker>$(win_path "$data/marker.txt")")"; rc=$?
        if [ ! -s "$data/display" ]; then
            x11_failed "$user" "$name's cmd.exe" "$out"
        elif [ "$rc" = 0 ] && tr -d '\r' < "$data/marker.txt" 2>/dev/null | grep -qx "$marker"; then
            ok "$name: cmd.exe printed $marker as $user without network, on display $(cat "$data/display")"
        else
            bad "$name: cmd.exe through proton as $user: exit $rc, marker file '$(tr -d '\r\n' < "$data/marker.txt" 2>/dev/null)'; last lines: $(printf '%s' "$out" | tail -n 5 | tr '\n' ' ')"
        fi
        runuser -u "$user" -- env WINEPREFIX="$data/proton/pfx" "$tree/files/bin/wineserver" -k >/dev/null 2>&1
        rm -rf "$data"
    done
    for tree in $wines; do
        name="$(basename "$tree")"
        # The loader and the server the runner names (runner.json entry, which runner-check accepted).
        read -r wine wineserver <<<"$(python3 -I -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        e = json.load(f).get("entry") or {}
except (OSError, ValueError):
    e = {}
print(e.get("wine") or "-", e.get("wineserver") or "-")
' "$tree/runner.json")"
        data="$(mktemp -d "$root/var/tmp/ruya-runner-check.XXXXXX")" || { bad "no scratch folder in /var/tmp"; continue; }
        chown -R "$user" "$data"
        for arch in x86_64 i386; do
            exe="$tree/lib/wine/$arch-windows/cmd.exe"
            out="$(unshare -n runuser -u "$user" -- env -i HOME="$data" PATH="$PATH" WINEPREFIX="$data/pfx" \
                WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all timeout 300 "$tree/$wine" "$exe" /c echo "$marker" 2>&1)"; rc=$?
            if [ "$rc" = 0 ] && printf '%s\n' "$out" | tr -d '\r' | grep -qx "$marker"; then
                ok "$name: $arch cmd.exe printed $marker as $user without network"
            else
                bad "$name: $arch cmd.exe through $wine as $user: exit $rc; last lines: $(printf '%s' "$out" | tail -n 5 | tr '\n' ' ')"
            fi
        done
        runuser -u "$user" -- env WINEPREFIX="$data/pfx" "$tree/$wineserver" -k >/dev/null 2>&1
        rm -rf "$data"
    done
fi

[ "$fail" = 0 ] && echo "vm-runner-check: all passed" || echo "vm-runner-check: FAILED"
exit "$fail"
