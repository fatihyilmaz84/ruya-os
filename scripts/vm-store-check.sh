#!/usr/bin/env bash
# Checks ruya-store (org.ruyaos.Store1, T-134) inside a running VM, as root. It builds a tiny signed
# Flatpak repository (one runtime, one app, no download), adds it through the service and drives
# install / uninstall over the system bus. Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-store-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-store-check.sh [check|security|clean]
# Boot the VM without a saved profile (plain smoke-test.ps1 -Keep): the "AddRemote by the shell is
# forbidden" check assumes no admin profile is active.
set -u
svc=org.ruyaos.Store1
path=/org/ruyaos/Store1
ifc=org.ruyaos.Store1
app=org.ruyaos.TestApp
rt=org.ruyaos.TestRuntime
remote=ruyaos-test
work=/var/lib/ruya-store-test
uid="$(id -u ruya-shell)"
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# A call as another user over the system bus.
as_shell() { runuser -u ruya-shell -- "$@"; }

build_repo() {
    rm -rf "$work"; mkdir -p "$work/gpg" "$work/rt/usr/share/ruya-test" "$work/app/files/bin" "$work/app/files/share/metainfo"
    chmod 700 "$work/gpg"
    # what flatpak build-init would have made
    mkdir -p "$work/rt/files" "$work/rt/var" "$work/app/var"
    gpg --homedir "$work/gpg" --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "ruya-store-test <test@example.org>" default default never >/dev/null 2>&1 || return 1
    key="$(gpg --homedir "$work/gpg" --list-keys --with-colons | awk -F: '/^pub/ {k=$5} END {print k}')"
    echo hello > "$work/rt/usr/share/ruya-test/hello"
    # Incompressible payload in the app: the install must take long enough to show progress.
    head -c 50000000 /dev/urandom > "$work/app/files/share/payload.bin"
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    printf '#!/bin/sh\necho hello\n' > "$work/app/files/bin/hello"; chmod 755 "$work/app/files/bin/hello"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=hello\n\n[Context]\nshared=network;\nsockets=pulseaudio;\n' "$app" "$rt" "$rt" > "$work/app/metadata"
    cat > "$work/app/files/share/metainfo/$app.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$app</id>
  <name>Test App</name>
  <summary>A tiny app for the store check</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <developer_name>RuyaOS</developer_name>
  <description><p>Nothing to see.</p></description>
</component>
EOF
    sign="--gpg-sign=$key --gpg-homedir=$work/gpg"
    flatpak build-export --runtime $sign "$work/repo" "$work/rt" stable || return 1
    flatpak build-finish --command=hello --share=network --socket=pulseaudio "$work/app" || return 1
    flatpak build-export $sign "$work/repo" "$work/app" stable || return 1
    flatpak build-update-repo $sign "$work/repo" || echo "(build-update-repo warned: appstream data may be missing, the store falls back to the id)"
    {
        printf '[Flatpak Repo]\nTitle=Store check\nUrl=file://%s/repo\n' "$work"
        printf 'GPGKey=%s\n' "$(gpg --homedir "$work/gpg" --export "$key" | base64 -w0)"
    } > "$work/test.flatpakrepo"
    # The same app in a repository without a key.
    flatpak build-export "$work/repo-unsigned" "$work/app" stable >/dev/null 2>&1
    printf '[Flatpak Repo]\nTitle=Unsigned\nUrl=file://%s/repo-unsigned\n' "$work" > "$work/unsigned.flatpakrepo"
}

wait_job() { # job-id, seconds -> prints the JobFinished status or nothing
    n=0
    while [ "$n" -lt "$2" ]; do
        st="$(grep -h "\"member\":\"JobFinished\"" "$work/signals.log" 2>/dev/null | grep "\"$1\"" | head -1)"
        [ -n "$st" ] && { echo "$st"; return 0; }
        sleep 1; n=$((n + 1))
    done
    return 1
}

case "${1:-check}" in
security)
    systemd-analyze security ruya-store --no-pager | tail -12
    ;;
clean)
    flatpak uninstall --system -y "$app" "$rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -rf "$work"
    ;;
check)
    echo "--- unit"
    systemctl is-active ruya-store && ok "ruya-store is active" || bad "ruya-store not active"
    systemctl status ruya-store --no-pager | head -8
    busctl --system status "$svc" | grep -E '^(UID|Comm)='

    echo "--- build a signed test repository"
    build_repo && ok "repository built" || { bad "cannot build the test repository"; exit 1; }

    echo "--- remotes of the image"
    flatpak remotes --system --columns=name,options
    flatpak remotes --system --columns=name | grep -qx fedora && bad "the fedora remote is still there" || ok "no fedora remote"
    flatpak remotes --system --columns=name,options | grep '^flathub' | grep -q 'no-gpg-verify' && bad "flathub is unsigned" || { flatpak remotes --system --columns=name | grep -qx flathub && ok "flathub is present and signed" || bad "flathub is missing"; }

    echo "--- AddRemote"
    out="$(as_shell busctl --system call "$svc" "$path" "$ifc" AddRemote ss x "file://$work/test.flatpakrepo")"
    echo "as ruya-shell: $out"
    case "$out" in 's "forbidden"') ok "AddRemote by a non-admin is forbidden";; *) bad "AddRemote by ruya-shell: $out";; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" AddRemote ss "$remote" "file://$work/test.flatpakrepo")"
    echo "as root: $out"
    case "$out" in 's "ok"') ok "AddRemote of a signed repository by root";; *) bad "AddRemote by root: $out";; esac
    out="$(busctl --system call "$svc" "$path" "$ifc" AddRemote ss unsigned "file://$work/unsigned.flatpakrepo")"
    echo "unsigned: $out"
    case "$out" in 's "invalid"') ok "an unsigned remote is refused";; *) bad "unsigned remote: $out";; esac
    flatpak remotes --system --columns=name,options
    busctl --system call "$svc" "$path" "$ifc" ListRemotes

    echo "--- catalogue"
    # AddRemote answers at once; the catalogue is read again in the background (it asks every remote).
    n=0
    until as_shell busctl --system call "$svc" "$path" "$ifc" Search s "TestApp" | grep -q "$app" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    echo "the new source's apps were in the catalogue after about $n s"
    list="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search s "")"
    echo "$list" | head -c 1500; echo
    echo "$list" | grep -q "$app" && ok "Search lists the test app" || bad "test app not in the catalogue"
    echo "$list" | grep -q '"installed" b false' && ok "not installed yet" || bad "installed flag"
    q="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search s "no-such-app-zzz")"
    echo "$q" | grep -q "$app" && bad "a query that matches nothing found the app" || ok "Search filters"
    busctl --system call "$svc" "$path" "$ifc" GetApp s "$app" | head -c 800; echo
    case "$(busctl --system call "$svc" "$path" "$ifc" GetApp s org.nope.Missing)" in 'sa{sv} "unknown-app"'*) ok "GetApp of an unknown id";; *) bad "GetApp unknown";; esac

    echo "--- Install"
    busctl --system --json=short monitor "$svc" > "$work/signals.log" 2>&1 &
    mon=$!
    # The shell's own Store singleton (D-Bus backend) watches the same service meanwhile.
    cp /root/vm-store-probe.qml "$work/probe.qml" && chmod 755 "$work" && chmod 644 "$work/probe.qml"
    pkill -f "probe[.]qml" 2>/dev/null   # a probe left over from an earlier run
    : > "$work/probe.log"; chmod 666 "$work/probe.log"
    as_shell env XDG_RUNTIME_DIR="/run/user/$uid" QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        timeout 170 ruya-shell --load "$work/probe.qml" > "$work/probe.log" 2>&1 &
    # Install only once the shell has read the catalogue (a slow VM: it can take many seconds).
    n=0
    until grep -a -q "available=true" "$work/probe.log" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    echo "the shell's Store was available after about $n s"
    out="$(as_shell busctl --system call "$svc" "$path" "$ifc" Install s "$app")"
    echo "$out"
    job="$(echo "$out" | sed -n 's/^ss "ok" "\(.*\)"$/\1/p')"
    [ -n "$job" ] && ok "Install queued $job" || bad "Install: $out"
    out2="$(as_shell busctl --system call "$svc" "$path" "$ifc" Install s "$app")"
    echo "second Install while the first runs: $out2"
    case "$out2" in 'ss "busy"'*|'ss "already-installed"'*) ok "a second Install is busy or already-installed";; *) bad "second Install: $out2";; esac
    fin="$(wait_job "$job" 180)" && ok "JobFinished arrived" || bad "no JobFinished within 180 s"
    echo "$fin" | head -c 400; echo
    echo "$fin" | grep -q '"ok"' && ok "JobFinished is ok" || bad "JobFinished is not ok"
    grep -h '"member":"JobProgress"' "$work/signals.log" | grep "\"$job\"" | head -8
    grep -h '"member":"JobProgress"' "$work/signals.log" | grep "\"$job\"" | sed -n 's/.*"data":\["[^"]*",\([0-9]*\),.*/\1/p' | awk '$1 > 0 && $1 < 100 {f=1} END {exit !f}' && ok "a JobProgress strictly between 0 and 100" || bad "no intermediate JobProgress"
    grep -h '"member":"JobProgress"' "$work/signals.log" | grep "\"$job\"" | grep -q '100' && ok "JobProgress reached 100" || bad "no JobProgress 100"
    grep -q '"member":"InstalledChanged"' "$work/signals.log" && ok "InstalledChanged sent" || bad "no InstalledChanged"
    # InstalledChanged comes before JobFinished
    first_ic="$(grep -n '"member":"InstalledChanged"' "$work/signals.log" | head -1 | cut -d: -f1)"
    first_jf="$(grep -n '"member":"JobFinished"' "$work/signals.log" | head -1 | cut -d: -f1)"
    [ -n "$first_ic" ] && [ -n "$first_jf" ] && [ "$first_ic" -lt "$first_jf" ] && ok "InstalledChanged before JobFinished" || bad "signal order ($first_ic, $first_jf)"
    inst="$(as_shell busctl --system call "$svc" "$path" "$ifc" ListInstalled)"
    echo "$inst" | grep -q "$app" && ok "ListInstalled shows the app" || bad "ListInstalled misses the app"
    flatpak list --system --app --columns=application,origin | grep "$app" && ok "flatpak agrees" || bad "flatpak does not list it"
    case "$(as_shell busctl --system call "$svc" "$path" "$ifc" Install s "$app")" in 'ss "already-installed"'*) ok "Install again: already-installed";; *) bad "Install again";; esac
    case "$(as_shell busctl --system call "$svc" "$path" "$ifc" Update s "$app")" in 'ss "no-update"'*) ok "Update: no-update";; *) bad "Update status";; esac

    # With Flathub's catalogue (thousands of apps) the shell needs a while to read it again after
    # every InstalledChanged: wait until it shows the app before it is uninstalled.
    n=0
    until grep -a -q "installed=1" "$work/probe.log" || [ "$n" -ge 120 ]; do sleep 1; n=$((n + 1)); done
    echo "the shell showed the app installed after about $n s"

    echo "--- Uninstall with data"
    # A profile's home (ruya-p*) lives in /var/home; make one for a user without privileges, with a
    # symlink inside the app's data that points at a file the service must not delete.
    home=/var/home/ruya-storetest
    mkdir -p "$home" && chown nobody:nobody "$home"
    echo victim > "$work/victim"
    runuser -u nobody -- sh -c "mkdir -p $home/.var/app/$app/data && touch $home/.var/app/$app/data/save.dat && ln -s $work/victim $home/.var/app/$app/data/link"
    other="$home/.var/app/org.ruyaos.OtherApp"
    runuser -u nobody -- mkdir -p "$other"
    out="$(as_shell busctl --system call "$svc" "$path" "$ifc" Uninstall sb "$app" true)"
    echo "$out"
    job="$(echo "$out" | sed -n 's/^ss "ok" "\(.*\)"$/\1/p')"
    [ -n "$job" ] && ok "Uninstall queued $job" || bad "Uninstall: $out"
    fin="$(wait_job "$job" 120)" && echo "$fin" | grep -q '"ok"' && ok "uninstall JobFinished ok" || bad "uninstall did not finish ok"
    as_shell busctl --system call "$svc" "$path" "$ifc" ListInstalled | grep -q "$app" && bad "still listed" || ok "ListInstalled is empty again"
    flatpak list --system --app | grep -q "$app" && bad "flatpak still has it" || ok "flatpak removed it"
    [ -e "$home/.var/app/$app" ] && bad "app data still there" || ok "the profile's app data was deleted"
    [ -e "$work/victim" ] && ok "a symlink in the data did not take its target along" || bad "the symlink target was deleted"
    [ -d "$other" ] && ok "another app's data is untouched" || bad "another app's data was deleted"
    rm -rf "$home"
    case "$(as_shell busctl --system call "$svc" "$path" "$ifc" Uninstall sb "$app" false)" in 'ss "not-installed"'*) ok "Uninstall again: not-installed";; *) bad "Uninstall status";; esac

    echo "--- bad input and other users"
    case "$(as_shell busctl --system call -- "$svc" "$path" "$ifc" Install s "--user")" in 'ss "invalid"'*) ok "an option as id is invalid";; *) bad "option id";; esac
    case "$(as_shell busctl --system call -- "$svc" "$path" "$ifc" Rollback ss "$app" "--x")" in 'ss "invalid"'*) ok "a bad commit is invalid";; *) bad "bad commit";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" Search s "" 2>&1)"; then
        bad "nobody could call Search: $out"
    else
        echo "$out"; ok "call from nobody refused"
    fi
    kill "$mon" 2>/dev/null

    echo "--- the shell's Store singleton (DBusStoreBackend), probe output"
    sleep 6
    grep -a "store-probe" "$work/probe.log" | sed 's/ apps=.*//' | uniq | head -12
    grep -a -q "store-probe: mock=false available=true" "$work/probe.log" && ok "the shell uses the D-Bus backend and the service answered" || bad "the shell never reported available=true"
    grep -a -q "catalogue=[0-9]* installed=0 .*" "$work/probe.log" && grep -a "catalogue=" "$work/probe.log" | head -1 | grep -q "$app" && ok "the shell saw the catalogue with the test app" || bad "the shell did not see the catalogue"
    grep -a -q "installed=1" "$work/probe.log" && ok "the shell saw the app installed (InstalledChanged -> ListInstalled)" || bad "the shell never saw the installed app"
    grep -a "installed=1" "$work/probe.log" | head -1 | grep -q "$app(installed)" && ok "and its catalogue flag changed" || bad "catalogue flag did not change"
    grep -a "installed=" "$work/probe.log" | tail -1 | grep -q "installed=0" && ok "the shell saw it uninstalled again" || bad "the shell still shows it installed"
    grep -a -i "warn\|Store1.*failed" "$work/probe.log" | head -5
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
