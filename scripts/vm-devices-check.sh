#!/usr/bin/env bash
# Checks the Devices service (audio T-128, network T-132, controller batteries T-161, Bluetooth T-173) inside a running VM booted with sound. Copy and run as root:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-devices-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-devices-check.sh [check|events|security|state|batteries|bluetooth|storage|thermal|thermal-fake]
# check (default): unit active, name owned by ruya-shell, ListSinks, a MasterVolume write reaches
# PipeWire, a call from another user is refused; then the network part: State is connected, Primary is
# the ethernet link with an IPv4 address, ListWifi and Scan answer, unknown ids are refused, another
# user is refused, pkcheck as the service's process allows the four NetworkManager actions it needs and
# refuses twelve others (T-180); then the batteries part: upower is installed and answers on the bus, ListBatteries answers an
# empty list (no controller in the VM; a real controller's battery is NOT checked here), another user is
# refused; then the Bluetooth part: bluetooth.service is active and org.bluez is on the bus, Powered is false,
# ListDevices answers an empty list, StartScan/Pair/Connect answer unavailable (no adapter in the VM; a real
# adapter and controller are NOT checked here), unknown ids and empty ids are refused, another user is
# refused. Needs the shell logged in (VM booted with -Audio).
# Then the storage part (T-196): GetSystemUsage matches `stat -f /var` (within 1 %), apps_bytes and data_bytes
# are measured in the background (data_bytes is -1 for now: the profile homes are 0700 profile users'),
# free + apps (+ data when known) + system add up to total, apps_bytes is close to du of
# /var/lib/flatpak, another user is refused, and installing a signed 80 MB test app through the Store makes
# apps_bytes grow and sends SystemUsageChanged (SKIP_APPS_GROWTH=1 skips the install; `storage` runs only this part).
# Then the thermal part (T-200): ListSensors answers; with a processor sensor in /sys (coretemp, k10temp or the
# x86_pkg_temp thermal zone) there is a cpu entry whose value is within 3 degrees of /sys, Level is normal when the
# VM idles; QEMU may expose no sensor at all: then there is no cpu entry (the list is empty) and Level is normal.
# Another user is refused. `thermal` runs only this part. `thermal-fake` (not part of check) points the service at a
# made-up sysfs tree (RUYA_THERMAL_SYSFS) and walks one sensor through normal, hot, critical and back, checking
# Level and the LevelChanged signal; it restarts ruya-devices twice and removes the tree.
# events: only the PipeWire event checks (T-133); IDLE=60 adds the idle-process count (also part of check; samples the process list for IDLE seconds).
# state: prints State and Primary (for the link test, see docs/dev-setup.md).
set -u
svc=org.ruyaos.Devices1
path=/org/ruyaos/Devices1
ifc=org.ruyaos.Devices1.Audio
net=org.ruyaos.Devices1.Network
bat=org.ruyaos.Devices1.Batteries
therm=org.ruyaos.Devices1.Thermal
bt=org.ruyaos.Devices1.Bluetooth
uid="$(id -u ruya-shell)"
as_shell() { runuser -u ruya-shell -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# T-193: polkit_expect <action-id> <pid> <want-exit> <text>. pkcheck answers 1 ("not authorized") for
# an id polkit does not know as well, so a mistyped or removed id would pass as "refused". The id
# must be registered first (pkaction --action-id exits 0 only then); otherwise this is a FAIL.
polkit_expect() {
    local action="$1" pid="$2" want="$3" text="$4" rc
    if ! pkaction --action-id "$action" >/dev/null 2>&1; then
        bad "polkit action $action is not registered (pkaction --action-id fails): its verdict means nothing"
        return
    fi
    pkcheck --action-id "$action" --process "$pid" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$want" ]; then ok "$text"; else bad "polkit verdict for $action: exit $rc (want $want)"; fi
}

# T-133: PipeWire is followed by events (one long-running pw-dump --monitor), not polled.
# $1 = seconds to watch the idle system for spawned processes (0 skips that part).
events_check() {
    idle="$1"
    echo "--- events (T-133)"
    mons="$(pgrep -x pw-dump | wc -l)"
    if [ "$mons" = 1 ]; then ok "exactly one pw-dump runs (the monitor)"; else bad "$mons pw-dump processes"; fi
    pgrep -a -x pw-dump
    set_outside() { as_shell wpctl set-volume @DEFAULT_AUDIO_SINK@ "$1"; }
    # Waits up to $2 tenths of a second for MasterVolume to read $1; prints the tenths it took.
    wait_volume() {
        n=0
        while [ "$n" -le "$2" ]; do
            [ "$(busctl --system get-property "$svc" "$path" "$ifc" MasterVolume 2>/dev/null)" = "u $1" ] && { echo "$n"; return 0; }
            sleep 0.1; n=$((n + 1))
        done
        return 1
    }
    set_outside 0.50; sleep 1
    set_outside 0.20
    if took="$(wait_volume 20 10)"; then ok "a wpctl change from outside shows in MasterVolume after ~$took/10 s"; else bad "MasterVolume did not follow wpctl within 1 s"; fi
    if [ "$idle" -gt 0 ]; then
        # Idle: sample the process list ten times a second; the 1 s poll started a pw-dump and a
        # wpctl every second (each lives some tens of ms), so it would be caught many times.
        monitor="$(pgrep -x pw-dump | head -1)"
        cpu0="$(as_shell systemctl --user show ruya-devices -p CPUUsageNSec --value)"
        seen=" "; samples=$((idle * 10)); i=0
        while [ "$i" -lt "$samples" ]; do
            for p in $(pgrep -x 'pw-dump|wpctl'); do
                [ "$p" = "$monitor" ] && continue
                case "$seen" in *" $p "*) ;; *) seen="$seen$p ";; esac
            done
            sleep 0.1; i=$((i + 1))
        done
        cpu1="$(as_shell systemctl --user show ruya-devices -p CPUUsageNSec --value)"
        spawned="$(echo $seen | wc -w)"
        cpu_ms=$(( (cpu1 - cpu0) / 1000000 ))
        echo "pw-dump/wpctl processes seen in ${idle} s idle (besides the monitor): $spawned; ruya-devices used ${cpu_ms} ms of CPU"
        if [ "$spawned" = 0 ]; then ok "idle: no pw-dump or wpctl started"; else bad "$spawned short-lived pw-dump/wpctl in ${idle} s idle"; fi
        if [ "$cpu_ms" -lt 200 ]; then ok "idle: the service used ${cpu_ms} ms of CPU"; else bad "idle CPU ${cpu_ms} ms"; fi
        [ "$(pgrep -x pw-dump | wc -l)" = 1 ] && ok "still only the monitor" || bad "more than the monitor"
    fi
    echo "restarting PipeWire"
    as_shell systemctl --user restart pipewire.service
    n=0
    until as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 || [ "$n" -ge 30 ]; do sleep 1; n=$((n + 1)); done
    sleep 3
    set_outside 0.30
    if took="$(wait_volume 30 40)"; then ok "service recovered after the PipeWire restart (MasterVolume followed in ~$took/10 s)"; else bad "MasterVolume did not follow after the PipeWire restart"; fi
    [ "$(pgrep -x pw-dump | wc -l)" = 1 ] && ok "one monitor again" || bad "monitor count after restart: $(pgrep -x pw-dump | wc -l)"
    as_shell systemctl --user status ruya-devices --no-pager | tail -6
    busctl --system set-property "$svc" "$path" "$ifc" MasterVolume u 50
}

# T-173: BlueZ behind Devices1.Bluetooth. No adapter in the VM: the service answers, the list is empty.
bluetooth_check() {
    echo "--- bluetooth (T-173): BlueZ behind Devices1.Bluetooth"
    if systemctl is-active bluetooth; then ok "bluetooth.service is active"; else bad "bluetooth.service not active"; fi
    if busctl --system status org.bluez >/dev/null 2>&1; then ok "org.bluez is on the system bus"; else bad "org.bluez is not on the bus"; fi
    ls /sys/class/bluetooth 2>/dev/null | head -3
    powered="$(busctl --system get-property "$svc" "$path" "$bt" Powered)"
    echo "Powered: $powered"
    case "$powered" in 'b false') ok "Powered is false (no adapter)";; *) bad "Powered is not false";; esac
    disc="$(busctl --system get-property "$svc" "$path" "$bt" Discovering)"
    case "$disc" in 'b false') ok "Discovering is false";; *) bad "Discovering is not false: $disc";; esac
    list="$(busctl --system call "$svc" "$path" "$bt" ListDevices)"
    echo "ListDevices: $list"
    case "$list" in 'aa{sv} 0') ok "ListDevices answers an empty list";; *) bad "ListDevices did not answer an empty aa{sv}";; esac
    scan="$(busctl --system call "$svc" "$path" "$bt" StartScan)"
    echo "StartScan: $scan"
    case "$scan" in 's "unavailable"') ok "StartScan answers unavailable";; *) bad "StartScan did not answer unavailable";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Pair s AA:BB:CC:DD:EE:FF)"
    case "$r" in 's "unavailable"') ok "Pair answers unavailable";; *) bad "Pair answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Pair s "")"
    case "$r" in 's "invalid"') ok "Pair with an empty id is invalid";; *) bad "Pair('') answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" Forget s AA:BB:CC:DD:EE:FF)"
    case "$r" in 's "unknown-device"') ok "Forget of an unknown device is refused";; *) bad "Forget answered: $r";; esac
    r="$(busctl --system call "$svc" "$path" "$bt" StopScan)"
    case "$r" in 's "ok"') ok "StopScan with no scan answers ok";; *) bad "StopScan answered: $r";; esac
    if out="$(busctl --system set-property "$svc" "$path" "$bt" Powered b true 2>&1)"; then
        bad "Powered could be set with no adapter"
    else
        echo "$out"; ok "Powered write without an adapter answers a D-Bus error"
    fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$bt" ListDevices 2>&1)"; then
        bad "nobody could call ListDevices: $out"
    else
        echo "$out"; ok "bluetooth call from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the Bluetooth calls" || bad "ruya-devices not active"
}

# T-196: Devices1.Storage.GetSystemUsage, the console's own storage. Compares the filesystem numbers
# with `stat -f /var`, waits for the first background measurement, checks that the parts add up,
# and that installing an app (a signed 80 MB test repository through the Store) makes apps_bytes
# grow and sends SystemUsageChanged. SKIP_APPS_GROWTH=1 leaves the install out.
stor=org.ruyaos.Devices1.Storage
store_svc=org.ruyaos.Store1
store_path=/org/ruyaos/Store1
usage_work=/var/lib/ruya-devices-usage-test
usage_remote=ruyaos-usage-test
usage_app=org.ruyaos.UsageTestApp
usage_rt=org.ruyaos.UsageTestRuntime

# usage_key <key>: one number out of `busctl call ... GetSystemUsage` (prints -2 when it cannot be read).
usage_key() {
    local line num
    line="$(busctl --system call "$svc" "$path" "$stor" GetSystemUsage 2>/dev/null)" || { echo -2; return; }
    num="$(echo "$line" | grep -o "\"$1\" x -\?[0-9]*" | head -1 | awk '{print $3}')"
    echo "${num:--2}"
}

usage_build_repo() {
    rm -rf "$usage_work"; mkdir -p "$usage_work/gpg" "$usage_work/rt/usr/share/ruya-test" "$usage_work/app/files/bin" "$usage_work/rt/files" "$usage_work/rt/var" "$usage_work/app/var"
    chmod 700 "$usage_work/gpg"
    gpg --homedir "$usage_work/gpg" --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "ruya-devices-usage-test <test@example.org>" default default never >/dev/null 2>&1 || return 1
    local key
    key="$(gpg --homedir "$usage_work/gpg" --list-keys --with-colons | awk -F: '/^pub/ {k=$5} END {print k}')"
    echo hello > "$usage_work/rt/usr/share/ruya-test/hello"
    head -c 80000000 /dev/urandom > "$usage_work/app/files/payload.bin"   # incompressible: apps_bytes must grow by about this
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$usage_rt" "$usage_rt" "$usage_rt" > "$usage_work/rt/metadata"
    printf '#!/bin/sh\necho hello\n' > "$usage_work/app/files/bin/hello"; chmod 755 "$usage_work/app/files/bin/hello"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=hello\n' "$usage_app" "$usage_rt" "$usage_rt" > "$usage_work/app/metadata"
    local sign="--gpg-sign=$key --gpg-homedir=$usage_work/gpg"
    flatpak build-export --runtime $sign "$usage_work/repo" "$usage_work/rt" stable || return 1
    flatpak build-finish --command=hello "$usage_work/app" || return 1
    flatpak build-export $sign "$usage_work/repo" "$usage_work/app" stable || return 1
    flatpak build-update-repo $sign "$usage_work/repo" >/dev/null 2>&1
    {
        printf '[Flatpak Repo]\nTitle=Usage check\nUrl=file://%s/repo\n' "$usage_work"
        printf 'GPGKey=%s\n' "$(gpg --homedir "$usage_work/gpg" --export "$key" | base64 -w0)"
    } > "$usage_work/test.flatpakrepo"
}

usage_clean() {
    flatpak uninstall --system -y "$usage_app" "$usage_rt" >/dev/null 2>&1
    flatpak remote-delete --system --force "$usage_remote" >/dev/null 2>&1
    rm -rf "$usage_work"
}

storage_usage_check() {
    echo "--- storage usage (T-196): GetSystemUsage"
    local raw total free apps data system n sum du_apps d mon before after out s_blocks s_unit s_avail s_total s_free tol
    raw="$(busctl --system call "$svc" "$path" "$stor" GetSystemUsage)"
    echo "GetSystemUsage: $raw"
    case "$raw" in 'a{sv} 5 '*) ok "GetSystemUsage answers five keys";; *) bad "GetSystemUsage did not answer five keys"; return;; esac
    total="$(usage_key total_bytes)"; free="$(usage_key free_bytes)"
    read -r s_blocks s_unit s_avail <<STATEOF
$(stat -f -c '%b %S %a' /var)
STATEOF
    s_total=$((s_blocks * s_unit)); s_free=$((s_avail * s_unit)); tol=$((s_total / 100))
    echo "service: total=$total free=$free; stat -f /var: total=$s_total free=$s_free (tolerance $tol)"
    if [ "$total" -ge 0 ] && [ "$((total - s_total))" -le "$tol" ] && [ "$((s_total - total))" -le "$tol" ]; then ok "total_bytes matches stat -f /var within 1 %"; else bad "total_bytes $total vs stat -f $s_total"; fi
    if [ "$free" -ge 0 ] && [ "$((free - s_free))" -le "$tol" ] && [ "$((s_free - free))" -le "$tol" ]; then ok "free_bytes matches stat -f /var within 1 % of the disk"; else bad "free_bytes $free vs stat -f $s_free"; fi

    # The first measurement runs in the background (the call never waits for it): -1 until done.
    n=0
    until [ "$(usage_key apps_bytes)" -ge 0 ] || [ "$n" -ge 120 ]; do sleep 1; n=$((n + 1)); done
    apps="$(usage_key apps_bytes)"; data="$(usage_key data_bytes)"; system="$(usage_key system_bytes)"
    total="$(usage_key total_bytes)"; free="$(usage_key free_bytes)"
    echo "measured after about $n s: apps=$apps data=$data system=$system"
    if [ "$apps" -ge 0 ]; then ok "apps_bytes was measured"; else bad "apps_bytes=$apps after $n s"; return; fi
    # The profile homes are 0700 users' directories the service (ruya-shell) cannot read: unknown, not a small number.
    if [ "$data" = -1 ]; then ok "data_bytes is -1 (the profile homes are not readable by the service)"; elif [ "$data" -ge 0 ]; then ok "data_bytes is known ($data): the homes were readable"; else bad "data_bytes=$data"; fi
    if [ "$system" -ge 0 ]; then ok "system_bytes is not negative"; else bad "system_bytes=$system"; fi
    sum=$((free + apps + system)); [ "$data" -gt 0 ] && sum=$((sum + data))
    if [ "$system" = 0 ] || { [ "$sum" -le "$total" ] && [ "$((total - sum))" -le "$((total / 100))" ]; }; then ok "free + apps + data + system add up to total (system is the rest)"; else bad "free+apps+data+system=$sum vs total=$total (data=$data)"; fi
    du_apps="$(du -s --block-size=1 -x /var/lib/flatpak 2>/dev/null | awk '{print $1}')"
    echo "du -sx /var/lib/flatpak (hard links counted once): $du_apps"
    if [ -n "$du_apps" ] && [ "$du_apps" -gt 0 ]; then
        d=$((apps - du_apps)); [ "$d" -lt 0 ] && d=$((0 - d))
        if [ "$d" -le "$((du_apps / 20 + 4000000))" ]; then ok "apps_bytes is close to du of /var/lib/flatpak"; else bad "apps_bytes $apps vs du $du_apps"; fi
    fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$stor" GetSystemUsage 2>&1)"; then
        bad "nobody could call GetSystemUsage: $out"
    else
        echo "$out"; ok "GetSystemUsage from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after GetSystemUsage" || bad "ruya-devices not active"

    if [ "${SKIP_APPS_GROWTH:-0}" = 1 ]; then echo "(SKIP_APPS_GROWTH=1: no install)"; return; fi
    echo "--- storage usage (T-196): apps_bytes grows after an install"
    usage_clean
    if usage_build_repo; then ok "test repository built"; else bad "cannot build the test repository"; usage_clean; return; fi
    busctl --system --json=short monitor "$svc" > "$usage_work/signals.log" 2>&1 &
    mon=$!
    sleep 1
    before="$(usage_key apps_bytes)"
    out="$(busctl --system call "$store_svc" "$store_path" "$store_svc" AddRemote ss "$usage_remote" "file://$usage_work/test.flatpakrepo")"
    case "$out" in 's "ok"') ok "test remote added";; *) bad "AddRemote: $out"; kill "$mon" 2>/dev/null; usage_clean; return;; esac
    n=0
    until as_shell busctl --system call "$store_svc" "$store_path" "$store_svc" Search sa{sv} "UsageTestApp" 0 | grep -q "$usage_app" || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    out="$(as_shell busctl --system call "$store_svc" "$store_path" "$store_svc" Install s "$usage_app")"
    echo "Install: $out"
    n=0
    until flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$usage_app" || [ "$n" -ge 180 ]; do sleep 1; n=$((n + 1)); done
    if flatpak list --system --app --columns=application 2>/dev/null | grep -qx "$usage_app"; then ok "the test app is installed (after about $n s)"; else bad "the test app did not install"; fi
    # InstalledChanged -> the service measures again and sends SystemUsageChanged.
    n=0
    until [ "$(usage_key apps_bytes)" -gt "$((before + 40000000))" ] || [ "$n" -ge 90 ]; do sleep 1; n=$((n + 1)); done
    after="$(usage_key apps_bytes)"
    echo "apps_bytes before=$before after=$after (about $n s after the install)"
    if [ "$after" -gt "$((before + 40000000))" ]; then ok "apps_bytes grew by $((after - before)) bytes after the install"; else bad "apps_bytes did not grow (before $before, after $after)"; fi
    kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    if grep -q '"member":"SystemUsageChanged"' "$usage_work/signals.log"; then ok "SystemUsageChanged was sent"; else bad "no SystemUsageChanged was seen"; fi
    usage_clean
}

# T-200: the cpu entry of ListSensors (its value), printed; nothing when there is none.
thermal_cpu_value() {
    busctl --system --json=short call "$svc" "$path" "$therm" ListSensors \
        | sed 's/},{"class"/}\n{"class"/g' \
        | sed -n -E 's/.*"class":\{"type":"s","data":"cpu"\}.*"value":\{"type":"d","data":(-?[0-9.]+)\}.*/\1/p' \
        | awk '{printf "%.1f", $1}'      # sd-json prints 40.0 as 40
}

# The processor temperature the kernel shows, in degrees (empty when the VM has none).
thermal_sys_cpu() {
    local h name f z
    for h in /sys/class/hwmon/hwmon*; do
        name="$(cat "$h/name" 2>/dev/null)"
        case "$name" in
        coretemp)
            for f in "$h"/temp*_label; do
                case "$(cat "$f" 2>/dev/null)" in "Package id"*) awk '{printf "%.1f", $1 / 1000}' "${f%_label}_input"; return;; esac
            done;;
        k10temp) awk '{printf "%.1f", $1 / 1000}' "$h/temp1_input"; return;;
        esac
    done
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] && { awk '{printf "%.1f", $1 / 1000}' "$z/temp"; return; }
    done
}

thermal_level() { busctl --system get-property "$svc" "$path" "$therm" Level; }

thermal_check() {
    echo "--- thermal (T-200): Devices1.Thermal"
    local raw lvl svc_cpu sys_cpu d out
    raw="$(busctl --system call "$svc" "$path" "$therm" ListSensors)"
    echo "ListSensors: $raw" | cut -c1-300
    case "$raw" in 'aa{sv} '*) ok "ListSensors answers an array of dictionaries";; *) bad "ListSensors did not answer aa{sv}"; return;; esac
    lvl="$(thermal_level)"; echo "Level: $lvl"
    case "$lvl" in 's "normal"') ok "Level is normal";; 's "warm"'|'s "hot"'|'s "critical"') bad "Level is $lvl on an idle VM";; *) bad "Level did not answer a level: $lvl";; esac
    sys_cpu="$(thermal_sys_cpu)"; svc_cpu="$(thermal_cpu_value)"
    echo "processor: service='$svc_cpu' sysfs='$sys_cpu'"
    if [ -z "$sys_cpu" ]; then
        if [ -z "$svc_cpu" ]; then ok "no processor sensor in /sys (QEMU): no cpu entry (the list may be empty)"; else bad "a cpu entry ($svc_cpu) without a sensor in /sys"; fi
    elif [ -z "$svc_cpu" ]; then
        bad "/sys has a processor sensor ($sys_cpu) but ListSensors has no cpu entry"
    else
        d="$(awk -v a="$svc_cpu" -v b="$sys_cpu" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d <= 3) ? "ok" : "far" }')"
        if [ "$d" = ok ]; then ok "the cpu entry ($svc_cpu) is within 3 degrees of /sys ($sys_cpu)"; else bad "the cpu entry $svc_cpu is not within 3 degrees of /sys $sys_cpu"; fi
    fi
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$therm" ListSensors 2>&1)"; then
        bad "nobody could call ListSensors: $out"
    else
        echo "$out"; ok "ListSensors from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the thermal calls" || bad "ruya-devices not active"
}

# Waits up to $2 seconds for Level to read $1; prints how long it took.
thermal_wait_level() {
    local n=0
    while [ "$n" -le "$2" ]; do
        [ "$(thermal_level)" = "s \"$1\"" ] && { echo "$n"; return 0; }
        sleep 1; n=$((n + 1))
    done
    return 1
}

# T-200: the policy over D-Bus, with a made-up sysfs. /sys cannot be replaced, so the service is
# pointed at a tree under /var/lib (its unit has a private /tmp) through RUYA_THERMAL_SYSFS.
thermal_fake_check() {
    echo "--- thermal (T-200): a made-up sysfs walks a sensor through the levels"
    local root=/var/lib/ruyaos-fakesys mon took d signals=/var/tmp/thermal-signals.log
    local hw="$root/class/hwmon/hwmon9"
    rm -rf "$root"; mkdir -p "$hw"
    echo coretemp > "$hw/name"; echo 'Package id 0' > "$hw/temp1_label"
    echo 40000 > "$hw/temp1_input"; echo 100000 > "$hw/temp1_crit"
    echo 1820 > "$hw/fan1_input"
    chmod -R a+rX "$root"
    as_shell systemctl --user set-environment RUYA_THERMAL_SYSFS="$root"
    as_shell systemctl --user restart ruya-devices
    d=0; until [ "$(thermal_cpu_value)" = 40.0 ] || [ "$d" -ge 30 ]; do sleep 1; d=$((d + 1)); done
    if [ "$(thermal_cpu_value)" = 40.0 ]; then ok "the service reads the made-up tree (cpu 40.0)"; else bad "the service did not pick up RUYA_THERMAL_SYSFS (cpu='$(thermal_cpu_value)')"; fi
    if [ "$(thermal_level)" = 's "normal"' ]; then ok "Level is normal at 40"; else bad "Level at 40: $(thermal_level)"; fi
    busctl --system --json=short monitor "$svc" > "$signals" 2>&1 &
    mon=$!
    sleep 1
    echo 92000 > "$hw/temp1_input"
    if took="$(thermal_wait_level hot 40)"; then ok "Level became hot after about $took s"; else bad "Level did not become hot at 92 ($(thermal_level))"; took=0; fi
    # The 10 s debounce: a reading at 92 for less than that never counts (5 s polls, so at least 9).
    if [ "$took" -ge 9 ]; then ok "not before the debounce ($took s)"; else bad "hot after only $took s: no debounce"; fi
    echo 97000 > "$hw/temp1_input"
    if took="$(thermal_wait_level critical 40)"; then ok "Level became critical after about $took s"; else bad "Level did not become critical at 97 ($(thermal_level))"; fi
    echo 40000 > "$hw/temp1_input"
    if took="$(thermal_wait_level normal 40)"; then ok "Level is normal again after about $took s"; else bad "Level did not return to normal ($(thermal_level))"; fi
    sleep 1
    kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    if grep -q '"member":"LevelChanged"' "$signals"; then ok "LevelChanged was sent"; else bad "no LevelChanged was seen"; fi
    grep -o '"member":"LevelChanged"' "$signals" | wc -l | xargs echo "LevelChanged signals:"
    rm -f "$signals"
    as_shell systemctl --user unset-environment RUYA_THERMAL_SYSFS
    as_shell systemctl --user restart ruya-devices
    rm -rf "$root"
}

case "${1:-check}" in
security)
    as_shell systemd-analyze --user security ruya-devices --no-pager | tail -15
    ;;
check)
    echo "--- unit"
    if as_shell systemctl --user is-active ruya-devices; then ok "ruya-devices is active"; else bad "ruya-devices not active"; fi
    as_shell systemctl --user status ruya-devices --no-pager | head -12

    echo "--- name owner"
    owner="$(busctl --system status "$svc" 2>/dev/null | grep -E '^(UID|Comm)=' | tr '\n' ' ')"
    echo "$owner"
    case "$owner" in *"UID=$uid"*) ok "name owned by ruya-shell (uid $uid)";; *) bad "name not owned by ruya-shell";; esac

    echo "--- ListSinks"
    sinks="$(busctl --system call "$svc" "$path" "$ifc" ListSinks)"
    echo "$sinks"
    echo "$sinks" | grep -q '"is_default" b true' && ok "a default sink is listed" || bad "no default sink"
    echo "wpctl default:"
    as_shell wpctl status | sed -n '/Sinks:/,/Sources:/p' | head -8

    echo "--- MasterVolume write"
    busctl --system set-property "$svc" "$path" "$ifc" MasterVolume u 37
    sleep 1
    busctl --system get-property "$svc" "$path" "$ifc" MasterVolume
    vol="$(as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@)"
    echo "wpctl: $vol"
    case "$vol" in "Volume: 0.37"*) ok "wpctl sees 0.37";; *) bad "wpctl volume is not 0.37";; esac
    busctl --system set-property "$svc" "$path" "$ifc" Muted b true
    sleep 1
    as_shell wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -q MUTED && ok "mute reaches wpctl" || bad "mute not seen"
    busctl --system set-property "$svc" "$path" "$ifc" Muted b false
    busctl --system set-property "$svc" "$path" "$ifc" MasterVolume u 50

    echo "--- channels and errors"
    busctl --system call "$svc" "$path" "$ifc" SetChannelVolume su media 40
    busctl --system call "$svc" "$path" "$ifc" SetChannelVolume su bass 40
    busctl --system call "$svc" "$path" "$ifc" SetDefaultSink s nope
    busctl --system get-property "$svc" "$path" "$ifc" ChannelVolumes

    echo "--- another user is refused"
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" ListSinks 2>&1)"; then
        bad "nobody could call ListSinks: $out"
    else
        echo "$out"; ok "call from nobody refused"
    fi

    echo "--- network (T-132): NetworkManager behind Devices1.Network"
    if systemctl is-active NetworkManager; then ok "NetworkManager is active"; else bad "NetworkManager not active"; fi
    state="$(busctl --system get-property "$svc" "$path" "$net" State)"
    echo "State: $state"
    case "$state" in 's "connected"') ok "State is connected";; *) bad "State is not connected";; esac
    primary="$(busctl --system get-property "$svc" "$path" "$net" Primary)"
    echo "Primary: $primary"
    case "$primary" in *'"kind" s "ethernet"'*) ok "Primary is ethernet";; *) bad "Primary is not ethernet";; esac
    echo "$primary" | grep -Eq '"ip" s "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' && ok "Primary has an IPv4 address" || bad "Primary has no IPv4 address"
    echo "nmcli says:"
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device | head -5
    wifi="$(busctl --system call "$svc" "$path" "$net" ListWifi)"
    echo "ListWifi: $wifi"
    case "$wifi" in "aa{sv} "*) ok "ListWifi answers (empty is fine in the VM)";; *) bad "ListWifi did not answer aa{sv}";; esac
    scan="$(busctl --system call "$svc" "$path" "$net" Scan)"
    echo "Scan: $scan"
    case "$scan" in 's "ok"') ok "Scan answers ok";; *) bad "Scan did not answer ok";; esac
    unknown="$(busctl --system call "$svc" "$path" "$net" Connect ss nowhere secret)"
    echo "Connect(nowhere): $unknown"
    case "$unknown" in 's "unknown-network"') ok "Connect to an unknown network is refused";; *) bad "unexpected Connect status";; esac
    unknown="$(busctl --system call "$svc" "$path" "$net" Forget s nowhere)"
    case "$unknown" in 's "unknown-network"') ok "Forget of an unknown network is refused";; *) bad "unexpected Forget status";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$net" ListWifi 2>&1)"; then
        bad "nobody could call ListWifi: $out"
    else
        echo "$out"; ok "network call from nobody refused"
    fi
    # T-180: polkit as the service's own process. pkcheck exit 0 = authorized without a prompt,
    # 1 = not authorized, 2 = would ask for a password. The allowed four are what network.rs
    # calls; everything else in the NetworkManager namespace is refused outright (exit 1), which
    # also overrides NetworkManager's own default for an active session.
    pid="$(pgrep -u ruya-shell -x ruya-devices | head -1)"
    if [ -z "$pid" ]; then bad "no ruya-devices process"; else
        for a in wifi.scan network-control settings.modify.system settings.modify.own; do
            polkit_expect "org.freedesktop.NetworkManager.$a" "$pid" 0 "polkit allows ruya-devices: NetworkManager $a"
        done
        for a in enable-disable-network enable-disable-wifi enable-disable-wwan enable-disable-connectivity-check enable-disable-statistics sleep-wake reload settings.modify.hostname settings.modify.global-dns checkpoint-rollback wifi.share.open wifi.share.protected; do
            polkit_expect "org.freedesktop.NetworkManager.$a" "$pid" 1 "polkit refuses ruya-devices: NetworkManager $a"
        done
    fi

    echo "--- batteries (T-161): UPower behind Devices1.Batteries"
    if command -v upower >/dev/null; then ok "upower is installed"; else bad "upower is not installed"; fi
    upower --version 2>/dev/null | head -2
    # UPower is D-Bus activated: the call below starts it if needed.
    if busctl --system call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower EnumerateDevices >/dev/null 2>&1; then ok "UPower answers on the system bus"; else bad "UPower does not answer"; fi
    if systemctl is-active upower; then ok "upower.service is active"; else bad "upower.service not active"; fi
    echo "UPower devices (type 12 = gaming input, none expected in the VM):"
    upower -d 2>/dev/null | grep -E "^Device:|  (model|native-path):" | head -12
    batt="$(busctl --system call "$svc" "$path" "$bat" ListBatteries)"
    echo "ListBatteries: $batt"
    case "$batt" in 'aa{sv} 0') ok "ListBatteries answers an empty list (no controller in the VM)";; *) bad "ListBatteries did not answer an empty aa{sv}";; esac
    if out="$(runuser -u nobody -- busctl --system call "$svc" "$path" "$bat" ListBatteries 2>&1)"; then
        bad "nobody could call ListBatteries: $out"
    else
        echo "$out"; ok "batteries call from nobody refused"
    fi
    as_shell systemctl --user is-active ruya-devices >/dev/null && ok "ruya-devices still active after the UPower calls" || bad "ruya-devices not active"

    bluetooth_check

    storage_usage_check

    thermal_check

    events_check "${IDLE:-60}"
    ;;
bluetooth)
    bluetooth_check
    ;;
storage)
    storage_usage_check
    ;;
thermal)
    thermal_check
    ;;
thermal-fake)
    thermal_fake_check
    ;;
events)
    events_check "${IDLE:-0}"
    ;;
batteries)
    busctl --system call "$svc" "$path" "$bat" ListBatteries
    ;;
state)
    # For the link test: the host runs `set_link <name> off|on` in the QEMU monitor, this shows the result.
    busctl --system get-property "$svc" "$path" "$net" State
    busctl --system get-property "$svc" "$path" "$net" Primary
    ;;
esac
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
