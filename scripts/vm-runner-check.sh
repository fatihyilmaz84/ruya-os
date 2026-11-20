#!/usr/bin/env bash
# modes: check steam
# Checks the Play platform on /usr (ADR-038, RUY-34) inside a running VM, as root, offline:
#   1. links: every L+ line of /usr/lib/tmpfiles.d/ruya-play-platform.conf is a link under
#      /var/lib/flatpak/extension to its folder on /usr, and that folder is there
#   2. launcher: /usr/lib/ruyaos/play/launcher/bin/ruya-play-launch is executable and, started
#      outside a sandbox, refuses with its own sentence (no /app/play.files): the static binary runs
#   3. runners: for each folder of /usr/lib/ruyaos/play/runners, ruya-pack runner-check (the
#      format's parser and runner hash) accepts its runner.json and computes the hash the image
#      wrote into .ruya-runner-hash, and /usr/lib/ruyaos/play/runners.list has its line
#   4. a Windows program runs through each Proton runner as a profile user, without network: the
#      runner's own cmd.exe through `proton waitforexitandrun` (ADR-037's argv, the
#      STEAM_COMPAT_* folders in a scratch data folder) prints a marker, under `unshare -n`.
#      Without a profile on the VM this step is a SKIP with its reason (the check creates none).
# Mode `steam` (RUY-35, after the Steam Flatpak is installed and was started once as a profile):
#   5. every Proton runner is linked into Steam's extension point
#      (com.valvesoftware.Steam.CompatibilityTool.<Name>/x86_64/stable) and carries its
#      compatibilitytool.vdf, so Steam lists the tool
#   6. the Steam Flatpak is installed, and in each profile that started Steam, Steam's own files
#      (steam.sh or ubuntu12_32) are in the root that holds config.vdf, and the default
#      compatibility tool (CompatToolMapping "0") is the newest Proton runner's tool (newest by
#      runner.json version): anything else FAILs, so it catches Steam replacing our entry on its
#      first run and a wrong config path
# Running a game inside a .play sandbox (the extension mounts, the 32-bit points) is
# vm-play-check.sh launch and launch-windows (RUY-902).
#
# ruya-pack: the Linux build of services/ruya-pack (scripts/ci-samples-linux.sh leaves it in
# services/target-samples/release/):
#   scp -P 2222 services/target-samples/release/ruya-pack scripts/vm-runner-check.sh root@127.0.0.1:/root/
#   ssh -p 2222 root@127.0.0.1 bash /root/vm-runner-check.sh check /root/ruya-pack
# Host fixtures (scripts/test-vm-checks.sh): RUYA_ROOT=<dir> puts every path the check reads below
# <dir>; the link targets in the tmpfiles file stay as written. JSON is parsed by key.
set -u
mode="${1:-check}"
pack="${2:-/root/ruya-pack}"
root="${RUYA_ROOT:-}"
conf="$root/usr/lib/tmpfiles.d/ruya-play-platform.conf"
play="$root/usr/lib/ruyaos/play"
launcher="$play/launcher/bin/ruya-play-launch"
marker=RUYA_RUNNER_OK
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

[ "$mode" = check ] || [ "$mode" = steam ] || { echo "usage: vm-runner-check.sh [check|steam] [ruya-pack]"; exit 2; }

if [ "$mode" = steam ]; then
    steam_ext="$root/var/lib/flatpak/extension"
    echo "--- Steam sees the runners"
    # The newest Proton runner by its runner.json version (the rule of resolve::compare_versions:
    # the numbers in the version, compared in order) and its tool name through Steam's link.
    newest="$(python3 -I - "$play/runners" <<'PYEOF'
import json, os, re, sys
best = None
for name in sorted(os.listdir(sys.argv[1])):
    try:
        with open(os.path.join(sys.argv[1], name, "runner.json"), encoding="utf-8") as f:
            r = json.load(f)
    except (OSError, ValueError):
        continue
    if r.get("kind") != "proton":
        continue
    key = [int(n) for n in re.findall(r"[0-9]+", str(r.get("version", "")))]
    if best is None or key > best[0]:
        best = (key, name)
if best:
    print(best[1])
PYEOF
)"
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
    if cut -f1 "$play/runners.list" 2>/dev/null | grep -qx "$name"; then ok "$name is in runners.list"; else bad "$name is not in $play/runners.list"; fi
    [ "$kind" = proton ] && protons="$protons $tree"
done
[ "$count" -ge 1 ] && ok "$count runner(s)" || bad "no runner under $play/runners"

echo "--- a Windows program through the runner, offline, as a profile user"
profile="$(busctl --system call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles 2>/dev/null | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
if [ -z "$protons" ]; then
    bad "no Proton runner to run a Windows program through"
elif [ -z "$profile" ]; then
    echo "SKIP: no profile on this VM: no Windows program was run (create one in the shell first; this check creates none)"
else
    user="ruya-$profile"
    for tree in $protons; do
        name="$(basename "$tree")"
        exe="$tree/files/lib/wine/x86_64-windows/cmd.exe"
        data="$(mktemp -d "$root/var/tmp/ruya-runner-check.XXXXXX")" || { bad "no scratch folder in /var/tmp"; continue; }
        mkdir -p "$data/proton/client"
        chown -R "$user" "$data"
        out="$(unshare -n runuser -u "$user" -- env -i HOME="$data" PATH="$PATH" \
            STEAM_COMPAT_DATA_PATH="$data/proton" STEAM_COMPAT_CLIENT_INSTALL_PATH="$data/proton/client" \
            WINEDEBUG=-all timeout 300 python3 "$tree/proton" waitforexitandrun "$exe" /c echo "$marker" 2>&1)"; rc=$?
        if [ "$rc" = 0 ] && printf '%s\n' "$out" | tr -d '\r' | grep -qx "$marker"; then
            ok "$name: cmd.exe printed $marker as $user without network"
        else
            bad "$name: cmd.exe through proton as $user: exit $rc; last lines: $(printf '%s' "$out" | tail -n 5 | tr '\n' ' ')"
        fi
        runuser -u "$user" -- env WINEPREFIX="$data/proton/pfx" "$tree/files/bin/wineserver" -k >/dev/null 2>&1
        rm -rf "$data"
    done
fi

[ "$fail" = 0 ] && echo "vm-runner-check: all passed" || echo "vm-runner-check: FAILED"
exit "$fail"
