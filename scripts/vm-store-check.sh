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
    until as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "TestApp" 0 | grep -q "$app" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    echo "the new source's apps were in the catalogue after about $n s"
    list="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "" 0)"
    echo "$list" | head -c 1500; echo
    echo "$list" | grep -q "$app" && ok "Search lists the test app" || bad "test app not in the catalogue"
    echo "$list" | grep -q '"installed" b false' && ok "not installed yet" || bad "installed flag"
    q="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "no-such-app-zzz" 0)"
    echo "$q" | grep -q "$app" && bad "a query that matches nothing found the app" || ok "Search filters"
    all_n="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "" 0 | grep -o '"id"' | wc -l)"
    pad_n="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "" 1 controller s gamepad | grep -o '"id"' | wc -l)"
    echo "apps without a filter: $all_n, with controller=gamepad: $pad_n"
    [ "$pad_n" -lt "$all_n" ] && ok "Search with controller=gamepad returns fewer apps" || bad "controller=gamepad did not filter ($pad_n of $all_n)"
    lim_n="$(as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "" 1 limit u 1 | grep -o '"id"' | wc -l)"
    [ "$lim_n" = 1 ] && ok "Search with limit=1 returns one app" || bad "limit=1 returned $lim_n"
    got="$(busctl --system call "$svc" "$path" "$ifc" GetApp s "$app")"
    echo "$got" | head -c 800; echo
    # T-156: the record carries new_permissions, empty for an app with no update.
    echo "$got" | grep -q '"new_permissions" as 0' && ok "GetApp reports an empty new_permissions" || bad "GetApp new_permissions: $got"
    case "$(busctl --system call "$svc" "$path" "$ifc" GetApp s org.nope.Missing)" in 'sa{sv} "unknown-app"'*) ok "GetApp of an unknown id";; *) bad "GetApp unknown";; esac

    echo "--- Install"
    busctl --system --json=short monitor "$svc" > "$work/signals.log" 2>&1 &
    mon=$!
    # The shell's own Store singleton (D-Bus backend) watches the same service meanwhile.
    cp /root/vm-store-probe.qml "$work/probe.qml" && chmod 755 "$work" && chmod 644 "$work/probe.qml"
    pkill -f "probe2?[.]qml" 2>/dev/null   # a probe left over from an earlier run
    : > "$work/probe.log"; chmod 666 "$work/probe.log"
    as_shell env XDG_RUNTIME_DIR="/run/user/$uid" QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        timeout 170 ruya-shell --load "$work/probe.qml" > "$work/probe.log" 2>&1 &
    # Install only once the shell has read the catalogue (a slow VM: it can take many seconds).
    n=0
    until grep -a -q "available=true" "$work/probe.log" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    echo "the shell's Store was available after about $n s"
    # The start-up read and the AppStream refresh each send CatalogChanged; let them finish so that
    # the Install is the only thing that can send signals from here on.
    prev=-1; n=0
    while [ "$n" -lt 24 ]; do
        cur="$(grep -c '"member":"CatalogChanged"' "$work/signals.log")"
        [ "$cur" = "$prev" ] && break
        prev="$cur"; sleep 5; n=$((n + 1))
    done
    sig_before="$(wc -l < "$work/signals.log")"
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
    if tail -n +"$((sig_before + 1))" "$work/signals.log" | grep -q '"member":"CatalogChanged"'; then
        bad "the Install sent CatalogChanged"
    else
        ok "the Install sent InstalledChanged but not CatalogChanged"
    fi
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
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "" 0 2>&1)"; then
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
    echo "--- the service restarts during an install (T-171): the shell ends the job as failed"
    # A fresh probe: the first one has used up its timeout by now.
    pkill -f "probe[.]qml" 2>/dev/null
    : > "$work/probe2.log"; chmod 666 "$work/probe2.log"
    # The probe's own Store must start the install: the shell's D-Bus backend only tracks jobs it
    # started (an Install by busctl would leave its job list empty and the test vacuous).
    sed "s/property string installApp: \"\"/property string installApp: \"$app\"/" "$work/probe.qml" > "$work/probe2.qml"
    chmod 644 "$work/probe2.qml"
    grep -q "installApp: \"$app\"" "$work/probe2.qml" || bad "could not set installApp in the probe copy"
    as_shell env XDG_RUNTIME_DIR="/run/user/$uid" QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        timeout 240 ruya-shell --load "$work/probe2.qml" > "$work/probe2.log" 2>&1 &
    # Restart only once the job is in the shell's Store.jobs (from its own JobProgress): then a
    # cut-short install can end only through the service-lost path, not the Install error reply.
    n=0
    until grep -a -q "store-probe: jobsChanged {\"$app\"" "$work/probe2.log" || [ "$n" -ge 120 ]; do sleep 0.2; n=$((n + 1)); done
    grep -a -q "store-probe: install requested $app" "$work/probe2.log" && ok "the shell's Store requested the install" || bad "the probe never requested the install"
    if grep -a -q "store-probe: jobsChanged {\"$app\"" "$work/probe2.log"; then
        ok "the job is in the shell's Store.jobs"
    else
        bad "the job never reached the shell's Store.jobs"; grep -a "store-probe" "$work/probe2.log" | tail -5
    fi
    systemctl restart ruya-store
    n=0
    until grep -a -q "store-probe: jobFinished $app failed" "$work/probe2.log" || [ "$n" -ge 40 ]; do sleep 1; n=$((n + 1)); done
    grep -a -q "store-probe: jobFinished $app failed" "$work/probe2.log" && ok "the shell ended the cut-short install as failed" || bad "the shell never ended the job of the old service"
    grep -a -q "store-probe: jobFinished $app ok" "$work/probe2.log" && bad "the install finished ok before the restart; the test proved nothing" || ok "no ok for that install"
    sleep 4
    grep -a " jobs=" "$work/probe2.log" | tail -1 | grep -q 'jobs={}' && ok "the shell's job list is empty after the restart" || bad "the shell still shows a job of the old service"
    # Once at its start, once more when the restarted service took the name (ListJobs, T-188).
    [ "$(grep -a -c 'store-probe: jobsReconciled' "$work/probe2.log")" -ge 2 ] && ok "the shell read the restarted service's job table" || bad "the shell never applied the job table after the restart"
    grep -a 'store-probe: jobsReconciled' "$work/probe2.log" | tail -1 | grep -q 'jobs={}' && ok "and shows no running job from it" || bad "the shell shows a running job after the restart"
    echo "--- ListJobs after the restart (T-188): the cut-short install is settled, nothing runs"
    # --json=short, and python3 picks fields by name: the order of the keys inside a record is
    # not part of the contract (the service's dictionaries have no order).
    jl="$(as_shell busctl --system --json=short call "$svc" "$path" "$ifc" ListJobs)"
    echo "$jl" | head -c 1500; echo
    # Prints "key=value" lines: counts of queued/running and finished records, then the fields of
    # the last record whose app is $1 (the list is oldest first, so that is the install just cut
    # short). A record without that app prints found=0.
    summarize_jobs() { # app; reads the JSON of ListJobs on stdin
        python3 -c '
import json, sys
app = sys.argv[1]
jobs = [{k: v["data"] for k, v in rec.items()} for rec in json.load(sys.stdin)["data"][0]]
print("active=%d" % sum(1 for j in jobs if j.get("state") in ("queued", "running")))
print("finished=%d" % sum(1 for j in jobs if j.get("state") == "finished"))
mine = [j for j in jobs if j.get("app") == app]
if not mine:
    print("found=0")
else:
    j = mine[-1]
    print("found=1")
    for key in ("id", "kind", "state", "status", "reason"):
        print("%s=%s" % (key, j.get(key, "")))
    print("number=%s" % j.get("id", "").replace("job-", ""))
' "$1"
    }
    summary="$(echo "$jl" | summarize_jobs "$app")" || summary=""
    echo "$summary"
    jfield() { echo "$summary" | sed -n "s/^$1=//p" | head -1; }
    [ "$(jfield active)" = "0" ] && ok "ListJobs lists no running or queued job" || bad "ListJobs shows a job of the old service as running or queued (active=$(jfield active))"
    [ "$(jfield found)" = "1" ] && ok "ListJobs lists the cut-short install" || bad "ListJobs has no job for $app"
    [ "$(jfield kind)" = "install" ] && ok "its kind is install" || bad "its kind: $(jfield kind)"
    [ "$(jfield state)" = "finished" ] && ok "its state is finished" || bad "its state: $(jfield state)"
    if [ "$(jfield status)" = "failed" ] && [ "$(jfield reason)" = "interrupted" ]; then
        ok "ListJobs reports it as failed, interrupted"
    elif [ "$(jfield status)" = "ok" ] && [ -z "$(jfield reason)" ] && flatpak list --system --app | grep -q "$app"; then
        ok "Flatpak had finished the install: ListJobs reports ok and the app is installed"
    else
        bad "the settled job is neither failed/interrupted nor ok with the app installed: status=$(jfield status) reason=$(jfield reason)"
    fi
    old_job_num="$(jfield number)"
    case "$old_job_num" in
        ''|*[!0-9]*) bad "no job number in the job id '$(jfield id)'"; old_job_num="" ;;
        *) ok "the job is named job-$old_job_num" ;;
    esac
    [ -s /var/lib/ruya-store/jobs ] && ok "the job table is kept in the state directory" || bad "/var/lib/ruya-store/jobs is missing or empty"
    ls -l /var/lib/ruya-store/jobs 2>/dev/null
    [ "$(jfield finished)" -ge 1 ] 2>/dev/null && ok "ListJobs lists finished jobs" || bad "no finished job listed"
    pkill -f "probe2[.]qml" 2>/dev/null
    flatpak uninstall --system -y "$app" >/dev/null 2>&1 || true   # an install cut short may have left it
    grep -a -i "warn\|Store1.*failed" "$work/probe2.log" | grep -v "store-probe" | head -5
    echo "--- removed outside the Store (T-182): Install is accepted again"
    # The service was restarted above: wait until it has read the catalogue again.
    n=0
    until as_shell busctl --system call "$svc" "$path" "$ifc" Search sa{sv} "TestApp" 0 | grep -q "$app" || [ "$n" -ge 120 ]; do sleep 1; n=$((n + 1)); done
    # Read only the signals from here on.
    : > "$work/signals.log"
    busctl --system --json=short monitor "$svc" >> "$work/signals.log" 2>&1 &
    mon=$!
    sleep 2
    out="$(as_shell busctl --system call "$svc" "$path" "$ifc" Install s "$app")"
    job="$(echo "$out" | sed -n 's/^ss "ok" "\(.*\)"$/\1/p')"
    [ -n "$job" ] && ok "Install queued $job" || bad "Install before the outside removal: $out"
    new_job_num="${job#job-}"
    case "$new_job_num" in ''|*[!0-9]*) new_job_num=0 ;; esac
    [ -n "${old_job_num:-}" ] && [ "$new_job_num" -gt "$old_job_num" ] && ok "job names continue after the restart ($job follows job-$old_job_num)" || bad "job name $job after job-${old_job_num:-?}: names must not be reused"
    fin="$(wait_job "$job" 180)" && echo "$fin" | grep -q '"ok"' && ok "the install finished ok" || bad "the install did not finish ok"
    case "$(as_shell busctl --system call "$svc" "$path" "$ifc" Install s "$app")" in 'ss "already-installed"'*) ok "Install of the installed app: already-installed";; *) bad "Install of the installed app";; esac
    # InstalledChanged signals the monitor has seen from line $1 of the log on. The monitor's
    # --json=short lines are parsed, not matched: the order of the keys is not part of the output.
    count_installed_changed() {
        python3 -c '
import json, sys
n = 0
for i, line in enumerate(open(sys.argv[1], encoding="utf-8", errors="replace")):
    if i < int(sys.argv[2]):
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if isinstance(msg, dict) and msg.get("member") == "InstalledChanged":
        n += 1
print(n)
' "$work/signals.log" "$1"
    }
    sleep 2   # the Install above has settled: its signals are in the log
    mark="$(wc -l < "$work/signals.log")"
    flatpak uninstall --system -y "$app" >/dev/null 2>&1 && ok "flatpak uninstall by hand" || bad "flatpak uninstall by hand failed"
    as_shell busctl --system call "$svc" "$path" "$ifc" ListInstalled | grep -q "$app" && bad "ListInstalled still lists the app removed by hand" || ok "ListInstalled follows Flatpak"
    # T-192: the correction announces itself, so a client does not show the removed app as
    # installed until its next read - and does so once.
    sleep 2
    seen="$(count_installed_changed "$mark")"
    [ "$seen" = 1 ] && ok "the correction after the outside removal sent InstalledChanged once" || bad "InstalledChanged seen $seen times after the outside removal (want 1)"
    as_shell busctl --system call "$svc" "$path" "$ifc" ListInstalled >/dev/null
    sleep 2
    seen="$(count_installed_changed "$mark")"
    [ "$seen" = 1 ] && ok "a second ListInstalled found nothing to correct and sent nothing" || bad "InstalledChanged seen $seen times after a second ListInstalled (want 1)"
    out="$(as_shell busctl --system call "$svc" "$path" "$ifc" Install s "$app")"
    echo "Install after the outside removal: $out"
    job="$(echo "$out" | sed -n 's/^ss "ok" "\(.*\)"$/\1/p')"
    [ -n "$job" ] && ok "Install is accepted after flatpak uninstall (no restart)" || bad "Install after the outside removal: $out"
    fin="$(wait_job "$job" 180)" && echo "$fin" | grep -q '"ok"' && ok "the second install finished ok" || bad "the second install did not finish ok"
    flatpak list --system --app | grep -q "$app" && ok "flatpak has the app again" || bad "flatpak does not have the app"
    kill "$mon" 2>/dev/null
    flatpak uninstall --system -y "$app" >/dev/null 2>&1 || true
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
