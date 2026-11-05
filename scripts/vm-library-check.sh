#!/usr/bin/env bash
# Checks ruya-library (org.ruyaos.Library1, T-112 / T-163 / T-183) inside a running VM, as root. It builds a
# tiny signed Flatpak repository (one runtime, a game and an app, no download, like
# vm-store-check.sh), adds it through Store1, installs and uninstalls through Store1 and watches
# Library1 over the system bus. Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-library-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-library-check.sh [check|seed|security|clean]
#   check     the whole cycle (install, title, update without Rescan, ItemsChanged, uninstall,
#             refused callers), cleans up after
#   seed      leaves the test game and app installed, for a screenshot of the shell (clean removes)
#   security  prints systemd-analyze security ruya-library
# Boot the VM with plain smoke-test.ps1 -Keep (or -Work -Keep for the screenshot).
set -u
svc=org.ruyaos.Library1
path=/org/ruyaos/Library1
ifc=org.ruyaos.Library1
store=org.ruyaos.Store1
spath=/org/ruyaos/Store1
game=org.ruyaos.TestGame
notes=org.ruyaos.TestNotes
rt=org.ruyaos.TestRuntime
remote=ruyaos-libtest
work=/var/lib/ruya-library-test
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

as_shell() { runuser -u ruya-shell -- "$@"; }
list_items() { as_shell busctl --system call "$svc" "$path" "$ifc" ListItems; }
# The text of one item's record: busctl prints a{sv} flat, and every record starts with its entry
# count (7: id, kind, title, source, launch, art, last_played), in no fixed key order.
record_of() { list_items | sed 's/ 7 "/\n&/g' | grep "\"flatpak:$1\""; }
signals() { local n; n="$(grep -c '"member":"ItemsChanged"' "$work/signals.log" 2>/dev/null)"; echo "${n:-0}"; }

# make_app <id> <name> <categories>: an app with a desktop entry in the repository
make_app() {
    local id="$1" name="$2" cats="$3" dir="$work/app-$1"
    mkdir -p "$dir/files/bin" "$dir/files/share/applications" "$dir/files/share/metainfo" "$dir/var"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=hello\n' "$id" "$rt" "$rt" > "$dir/metadata"
    printf '#!/bin/sh\necho hello\n' > "$dir/files/bin/hello"; chmod 755 "$dir/files/bin/hello"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=hello\nCategories=%s\n' "$name" "$cats" > "$dir/files/share/applications/$id.desktop"
    cat > "$dir/files/share/metainfo/$id.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$id</id>
  <name>$name</name>
  <summary>A tiny app for the library check</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <developer_name>RuyaOS</developer_name>
  <description><p>Nothing to see.</p></description>
</component>
EOF
    flatpak build-finish --command=hello "$dir" || return 1
    flatpak build-export $sign "$work/repo" "$dir" stable || return 1
}

build_repo() {
    rm -rf "$work"; mkdir -p "$work/gpg" "$work/rt/usr/share/ruya-test" "$work/rt/files" "$work/rt/var"
    chmod 700 "$work/gpg"
    gpg --homedir "$work/gpg" --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "ruya-library-test <test@example.org>" default default never >/dev/null 2>&1 || return 1
    key="$(gpg --homedir "$work/gpg" --list-keys --with-colons | awk -F: '/^pub/ {k=$5} END {print k}')"
    echo hello > "$work/rt/usr/share/ruya-test/hello"
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    sign="--gpg-sign=$key --gpg-homedir=$work/gpg"
    flatpak build-export --runtime $sign "$work/repo" "$work/rt" stable || return 1
    make_app "$game" "Test Game" "Game;ArcadeGame;" || return 1
    make_app "$notes" "Test Notes" "Utility;" || return 1
    flatpak build-update-repo $sign "$work/repo" || echo "(build-update-repo warned: appstream data may be missing)"
    {
        printf '[Flatpak Repo]\nTitle=Library check\nUrl=file://%s/repo\n' "$work"
        printf 'GPGKey=%s\n' "$(gpg --homedir "$work/gpg" --export "$key" | base64 -w0)"
    } > "$work/test.flatpakrepo"
}

add_remote() {
    local out
    out="$(busctl --system call "$store" "$spath" "$store" AddRemote ss "$remote" "file://$work/test.flatpakrepo")"
    case "$out" in 's "ok"') ok "AddRemote of the test repository by root";; *) bad "AddRemote: $out"; return 1;; esac
    # The catalogue is read again in the background; Install needs the app in it.
    local n=0
    until as_shell busctl --system call "$store" "$spath" "$store" Search 'sa{sv}' "TestGame" 0 | grep -q "$game" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    echo "the test apps were in the store catalogue after about $n s"
}

# install_app <id>: queue through Store1 as ruya-shell
install_app() {
    local out
    out="$(as_shell busctl --system call "$store" "$spath" "$store" Install s "$1")"
    case "$out" in 'ss "ok"'*) ok "Install $1 queued";; *) bad "Install $1: $out"; return 1;; esac
}

# wait_listed <id> <yes|no> <seconds>: until ListItems has (or has not) flatpak:<id>
wait_listed() {
    local n=0
    while [ "$n" -lt "$3" ]; do
        if list_items | grep -q "\"flatpak:$1\""; then [ "$2" = yes ] && { echo "$n"; return 0; }
        else [ "$2" = no ] && { echo "$n"; return 0; }; fi
        sleep 1; n=$((n + 1))
    done
    return 1
}

# wait_record <id> <text> <seconds>: until the item's record contains <text> (no Rescan is sent)
wait_record() {
    local n=0
    while [ "$n" -lt "$3" ]; do
        if record_of "$1" | grep -q "$2"; then echo "$n"; return 0; fi
        sleep 1; n=$((n + 1))
    done
    return 1
}

case "${1:-check}" in
security)
    systemd-analyze security ruya-library --no-pager | tail -14
    ;;
clean)
    flatpak uninstall --system -y "$game" "$notes" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    ;;
seed)
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    add_remote || exit 1
    install_app "$game"; install_app "$notes"
    wait_listed "$game" yes 180 >/dev/null && wait_listed "$notes" yes 60 >/dev/null && ok "both are in the library" || bad "not listed"
    ;;
check)
    echo "--- unit"
    systemctl is-active ruya-library && ok "ruya-library is active" || bad "ruya-library not active"
    systemctl status ruya-library --no-pager | head -8
    uid="$(id -u ruya-library 2>/dev/null)"
    owner="$(busctl --system status "$svc" | sed -n 's/^UID=\([0-9]*\).*/\1/p')"
    echo "the name is owned by uid $owner (ruya-library is $uid)"
    [ -n "$uid" ] && [ "$owner" = "$uid" ] && ok "the service runs as its own user" || bad "owner uid"
    [ "$uid" != 0 ] && ok "not root" || bad "root"

    echo "--- the installed Flatpaks are listed"
    base="$(list_items)"
    echo "$base" | head -c 1200; echo
    # every installed app of the system installation, with the right id
    missing=0
    for id in $(flatpak list --system --app --columns=application); do
        echo "$base" | grep -q "\"flatpak:$id\"" || { echo "missing: $id"; missing=1; }
    done
    [ "$missing" = 0 ] && ok "ListItems has every app of 'flatpak list --system --app'" || bad "ListItems misses installed apps"
    echo "$base" | grep -q '"steam:' && bad "a Steam item in the image" || ok "no Steam items (the Steam source is off in the image)"
    echo "$base" | grep -q "$game" && bad "the test game is there before it is installed" || ok "the test game is not installed yet"

    echo "--- build a signed test repository"
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }
    add_remote || exit 1
    stdbuf -oL busctl --system --json=short monitor "$svc" > "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2

    echo "--- Install: the app appears, ItemsChanged fires"
    before="$(signals)"
    t0="$(date +%s)"
    install_app "$game" || exit 1
    s="$(wait_listed "$game" yes 180)" && ok "the game is in ListItems after about $s s" || bad "the game never appeared in ListItems"
    t1="$(date +%s)"; echo "install to listed: $((t1 - t0)) s"
    sleep 1
    after="$(signals)"
    [ "$after" -gt "$before" ] && ok "ItemsChanged fired ($before -> $after)" || bad "no ItemsChanged after the install"
    rec="$(record_of "$game")"
    echo "$rec" | head -c 600; echo
    echo "$rec" | grep -q '"kind" s "game"' && ok "kind is game (Categories has Game)" || bad "kind of the test game: $rec"
    # `flatpak list` prints the id's last part ("TestGame") because the test repository has no
    # appstream catalogue; the service takes the name from the exported desktop entry (T-183).
    echo "$rec" | grep -q '"title" s "Test Game"' && ok "title is the desktop entry's Name, not the id's last part" || bad "title: $rec"
    echo "$rec" | grep -q '"source" s "flatpak"' && ok "source is flatpak" || bad "source"
    echo "$rec" | grep -q "\"launch\" s \"flatpak:$game\"" && ok "launch spec" || bad "launch"

    before="$(signals)"
    install_app "$notes" || exit 1
    wait_listed "$notes" yes 120 >/dev/null && ok "the second app is listed" || bad "the second app never appeared"
    rec="$(record_of "$notes")"
    echo "$rec" | grep -q '"kind" s "app"' && ok "kind is app (no Game category)" || bad "kind of the test app: $rec"

    echo "--- Update: a renamed and recategorised app is seen without Rescan (T-183)"
    before="$(signals)"
    make_app "$game" "Test Game Reloaded" "Utility;" || bad "cannot build the new version"
    flatpak build-update-repo $sign "$work/repo" >/dev/null 2>&1
    flatpak update --system -y --noninteractive "$game" && ok "flatpak update of the test game" || bad "flatpak update failed"
    s="$(wait_record "$game" '"title" s "Test Game Reloaded"' 60)" && ok "the new title is listed after about $s s, no Rescan" || bad "the title did not change: $(record_of "$game")"
    record_of "$game" | grep -q '"kind" s "app"' && ok "the new category made it an app" || bad "kind after the update: $(record_of "$game")"
    sleep 1
    after="$(signals)"
    [ "$after" -gt "$before" ] && ok "ItemsChanged fired for the update ($before -> $after)" || bad "no ItemsChanged after the update"

    echo "--- Uninstall: the app disappears, ItemsChanged fires"
    before="$(signals)"
    out="$(as_shell busctl --system call "$store" "$spath" "$store" Uninstall sb "$game" false)"
    case "$out" in 'ss "ok"'*) ok "Uninstall queued";; *) bad "Uninstall: $out";; esac
    s="$(wait_listed "$game" no 120)" && ok "the game left ListItems after about $s s" || bad "the game is still listed"
    sleep 1
    after="$(signals)"
    [ "$after" -gt "$before" ] && ok "ItemsChanged fired ($before -> $after)" || bad "no ItemsChanged after the uninstall"
    list_items | grep -q "\"flatpak:$notes\"" && ok "the other app is still listed" || bad "the other app vanished"

    echo "--- Rescan and other users"
    before="$(signals)"
    as_shell busctl --system call "$svc" "$path" "$ifc" Rescan >/dev/null && ok "Rescan by ruya-shell" || bad "Rescan failed"
    sleep 1
    [ "$(signals)" = "$before" ] && ok "Rescan of an unchanged library sends nothing" || bad "Rescan sent ItemsChanged for an unchanged list"
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListItems 2>&1)"; then
        bad "nobody could call ListItems: $out"
    else
        echo "$out"; ok "ListItems from nobody refused"
    fi
    if out="$(runuser -u ruya-library -- busctl --system call "$svc" "$path" "$ifc" ListItems 2>&1)"; then
        bad "ruya-library could call itself: $out"
    else
        ok "the service account may not call it either"
    fi
    out="$(busctl --system call "$svc" "$path" "$ifc" ListItems 2>&1)" && ok "root may call ListItems" || bad "root refused: $out"
    kill "$mon" 2>/dev/null
    journalctl -u ruya-library -b --no-pager | tail -8

    echo "--- clean up"
    "$0" clean
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
