#!/usr/bin/env bash
# modes: check download parse reboot security settings
# Checks ruya-update (org.ruyaos.Update1, T-151) inside a running VM, as root. Prepare: the VM
# tracks <wsl-ip>:5000/ruyaos:stable (bootc switch, then reboot) and the registry holds a NEWER
# image under that tag (docs/dev-setup.md, "Update check"). Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-update-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-update-check.sh [check|download|security|settings|reboot]
# Boot the VM without a saved profile (plain smoke-test.ps1 -Keep): "Rollback by the shell is
# forbidden" assumes no admin profile is active. After "check", restart from Settings (or
# `systemctl reboot`) and compare the version row.
set -u
svc=org.ruyaos.Update1
path=/org/ruyaos/Update1
ifc=org.ruyaos.Update1
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

status() { busctl --system call "$svc" "$path" "$ifc" GetStatus --json=short; }
# one key of the record, e.g. field state -> checking
field() { status | python3 -c "import json,sys; v=json.load(sys.stdin)['data'][0]['$1']['data']; print(str(v).lower() if isinstance(v, bool) else v)"; }
call() { busctl --system call "$svc" "$path" "$ifc" "$@" | sed -E 's/^ss? "([^"]*)".*/\1/'; }
wait_state() { # wait_state <not-this-state> <seconds>
    local i=0
    while [ "$i" -lt "$2" ]; do
        [ "$(field state)" != "$1" ] && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# The image job (RUY-29): GetDownloadJob's record and ruya-update's journal line for each run.
# One key of the job record, from `busctl --json=short` on stdin ("" when the key is absent).
job_key() { python3 -c "import json,sys; d=json.load(sys.stdin)['data']; v=d[1].get('$1',{}).get('data',''); print(str(v).lower() if isinstance(v, bool) else v)"; }
job() { busctl --system call "$svc" "$path" "$ifc" GetDownloadJob --json=short; }
jfield() { job | job_key "$1"; }
# The layers the machine already had at the start of each run of job $1, one line per run, from
# ruya-update's journal on stdin ("ruya-update: download <id>: <n> layers (<b> bytes) here, ...").
cached_layers() { sed -nE "s/.*ruya-update: download $1: ([0-9]+) layers \([0-9]+ bytes\) here, .*/\1/p"; }
wait_job() { # wait_job <key> <value> <seconds>
    local i=0
    while [ "$i" -lt "$3" ]; do
        [ "$(jfield "$1")" = "$2" ] && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}
wait_bytes() { # wait_bytes <more-than> <seconds>: bytes_done grows past the value in phase download
    local i=0
    while [ "$i" -lt "$2" ]; do
        [ "$(jfield phase)" = download ] && [ "$(jfield bytes_done)" -gt "$1" ] 2>/dev/null && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}
deployments() { bootc status --json | python3 -c "import json,sys; s=json.load(sys.stdin)['status']; d=lambda k: (s.get(k) or {}).get('image',{}).get('imageDigest',''); print(d('booted'), d('rollback'), 'staged=' + d('staged'))"; }

if [ "${1:-check}" = parse ]; then
    # Host fixtures (scripts/test-vm-checks.sh): `parse job <key>` and `parse cached <job id>` read stdin.
    case "${2:-}" in
        job) job_key "$3" ;;
        cached) cached_layers "$3" ;;
        *) echo "usage: vm-update-check.sh parse job <key> | parse cached <job id>"; exit 2 ;;
    esac
    exit $?
fi

# download (RUY-29): the OS download as a job, with bytes, pause, resume and cancel. Prepare as
# for `check` (the registry holds a newer image under the tracked tag), or with the oci-archive
# route of scripts/dell-update.sh (the console tracks an oci-archive path; copy a newer archive
# over that path). Run 1 is cancelled: nothing staged, the deployments unchanged. Run 2 is paused
# after some layers, survives a service restart paused, resumes with more layers cached than
# its first run had, and ends staged. Leaves the update staged, like `check`.
if [ "${1:-check}" = download ]; then
    started="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl is-active --quiet ruya-update && ok "ruya-update is active" || { bad "ruya-update is not active"; exit 1; }
    wait_state checking 120; wait_state downloading 900
    [ "$(field state)" = staged ] && { echo "FAIL: an update is already staged (boot it or roll back first)"; exit 1; }
    [ "$(call Check)" = ok ] || { echo "FAIL: Check did not start"; exit 1; }
    wait_state checking 300
    [ -n "$(field available)" ] && ok "newer image found: $(field available)" || { echo "FAIL: no newer image (state $(field state), error '$(field error)')"; exit 1; }
    [ "$(call PauseDownload)" = wrong-state ] && ok "PauseDownload with nothing downloading: wrong-state" || bad "PauseDownload with nothing downloading not wrong-state"
    [ "$(call ResumeDownload)" = wrong-state ] && ok "ResumeDownload with nothing paused: wrong-state" || bad "ResumeDownload with nothing paused not wrong-state"
    before="$(deployments)"

    # Run 1: cancelled while bytes arrive.
    [ "$(call Download)" = ok ] && ok "Download started" || { bad "Download did not start"; exit 1; }
    id1="$(jfield id)"
    [ "$(jfield source)/$(jfield kind)" = update/os ] && ok "job $id1: source update, kind os" || bad "job source/kind: $(jfield source)/$(jfield kind)"
    if wait_bytes 0 300; then
        b1="$(jfield bytes_done)"; ok "bytes move: $b1 of $(jfield bytes_total), $(jfield rate_bps) B/s"
    else
        bad "no bytes within 300 s (phase $(jfield phase), state $(field state))"; exit 1
    fi
    wait_bytes "$b1" 30 && ok "and keep moving: $(jfield bytes_done)" || bad "bytes_done stood still at $b1"
    [ "$(call CancelDownload)" = ok ] && ok "CancelDownload: ok" || bad "CancelDownload not ok"
    wait_job state finished 60 && [ "$(jfield status)" = cancelled ] && ok "job finished: cancelled" || bad "job state $(jfield state), status $(jfield status)"
    [ "$(field state)" = idle ] && [ -n "$(field available)" ] && ok "state idle, the update still available" || bad "after the cancel: state $(field state), available '$(field available)'"
    [ "$(deployments)" = "$before" ] && ok "bootc status unchanged: $before" || bad "deployments changed: $before -> $(deployments)"
    pgrep -x bootc >/dev/null && bad "a bootc still runs after the cancel" || ok "no bootc left running"

    # Run 2: paused, kept over a service restart, resumed to staged.
    [ "$(call Download)" = ok ] && ok "Download again" || { bad "second Download did not start"; exit 1; }
    id2="$(jfield id)"
    [ "$id2" != "$id1" ] && ok "a new job: $id2" || bad "the cancelled job's id again: $id2"
    wait_bytes 0 300 || { bad "run 2: no bytes within 300 s"; exit 1; }
    echo "letting layers arrive for 40 s"
    sleep 40
    [ "$(jfield phase)" = download ] || { bad "run 2 left the download phase within 40 s: no pause possible"; exit 1; }
    p1="$(jfield percent)"
    [ "$(call PauseDownload)" = ok ] && ok "PauseDownload at $p1 %: ok" || bad "PauseDownload not ok"
    wait_job state paused 60 && ok "job paused" || bad "job state $(jfield state) after the pause"
    p2="$(jfield percent)"
    [ "$p2" -ge "$p1" ] && ok "percent kept: $p2" || bad "percent went back: $p1 -> $p2"
    [ "$(jfield resumable)" = true ] && ok "still resumable" || bad "a paused job is not resumable"
    [ "$(field state)" = idle ] && ok "state idle while paused" || bad "state $(field state) while paused"
    [ "$(deployments)" = "$before" ] && ok "nothing staged while paused" || bad "deployments changed while paused: $(deployments)"
    systemctl restart ruya-update && sleep 3
    [ "$(jfield id)" = "$id2" ] && [ "$(jfield state)" = paused ] && ok "a service restart keeps the job paused" || bad "after a restart: job $(jfield id) $(jfield state)"
    [ "$(call ResumeDownload)" = ok ] && ok "ResumeDownload: ok" || bad "ResumeDownload not ok"
    wait_job state running 30 || bad "job not running after the resume"
    runs=""; i=0
    while [ "$i" -lt 300 ]; do  # the resumed run's first ProgressBytes (after bootc opens the image)
        runs="$(journalctl -u ruya-update --since "$started" --no-pager -o cat | cached_layers "$id2")"
        [ "$(echo "$runs" | grep -c .)" -ge 2 ] && break
        sleep 1; i=$((i + 1))
    done
    [ "$(jfield percent)" -ge "$p2" ] && ok "percent did not go back on resume: $(jfield percent)" || bad "percent went back on resume: $p2 -> $(jfield percent)"
    first="$(echo "$runs" | head -1)"; last="$(echo "$runs" | tail -1)"
    if [ "$(echo "$runs" | grep -c .)" -ge 2 ] && [ "$last" -gt "$first" ]; then
        ok "the resumed run had more layers cached: $first -> $last"
    else
        bad "cached layers per run of $id2: $(echo "$runs" | tr '\n' ' ')"
    fi
    if wait_job phase install 900; then
        [ "$(call PauseDownload)" = unsupported ] && ok "PauseDownload during the install: unsupported" || bad "PauseDownload during the install not unsupported"
        [ "$(call CancelDownload)" = unsupported ] && ok "CancelDownload during the install: unsupported" || bad "CancelDownload during the install not unsupported"
    else
        bad "no install phase within 900 s"
    fi
    wait_state downloading 900 && [ "$(field state)" = staged ] && ok "staged: $(field staged)" || bad "state $(field state), error '$(field error)'"
    [ "$(jfield status)" = ok ] && [ "$(jfield percent)" = 100 ] && ok "job finished ok at 100 %" || bad "job status $(jfield status), percent $(jfield percent)"
    deployments | grep -q 'staged=sha256' && ok "bootc status has the staged deployment" || bad "bootc status has no staged deployment"
    stats="$(busctl --system call "$svc" "$path" "$ifc" GetDownloadStats u 1 --json=short)"
    echo "$stats" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; sys.exit(0 if d[0]=='ok' and d[1] and d[1][0]['bytes']['data']>0 else 1)" \
        && ok "GetDownloadStats counts today's bytes" || bad "GetDownloadStats: $stats"
    [ "$fail" = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
    exit "$fail"
fi

settings_checks() {
    # T-154: the automatic-restart setting and the activity report.
    [ "$(field auto_restart)" = true ] && ok "auto_restart is on by default" || bad "auto_restart is not on at start"
    out="$(runuser -u ruya-shell -- busctl --system call "$svc" "$path" "$ifc" SetAutoRestart b false 2>&1)"
    echo "$out" | grep -q '"forbidden"' && ok "SetAutoRestart by the shell without an admin profile: forbidden" || bad "SetAutoRestart by the shell answered: $out"
    [ "$(field auto_restart)" = true ] && ok "and the setting did not change" || bad "a refused SetAutoRestart changed the setting"
    [ "$(call SetAutoRestart b false)" = ok ] && ok "SetAutoRestart false (root): ok" || bad "SetAutoRestart false not ok"
    [ "$(field auto_restart)" = false ] && ok "auto_restart is off in the record" || bad "auto_restart still on"
    [ "$(cat /var/lib/ruya-update/auto_restart)" = off ] && ok "stored in /var/lib/ruya-update" || bad "no stored setting"
    systemctl restart ruya-update && sleep 3
    [ "$(field auto_restart)" = false ] && ok "the setting survives a service restart" || bad "setting lost over a restart"
    [ "$(call SetAutoRestart b true)" = ok ] && [ "$(field auto_restart)" = true ] && ok "SetAutoRestart true: back on" || bad "could not turn it back on"
    if runuser -u ruya-shell -- busctl --system call "$svc" "$path" "$ifc" ReportActivity b false >/dev/null 2>&1; then
        ok "ReportActivity by the shell: answered"
    else
        bad "ReportActivity by the shell failed"
    fi
    [ "$(field last_check)" != 0 ] && ok "last_check kept over the service restart" || bad "last_check lost over a restart"
}

if [ "${1:-check}" = settings ]; then
    settings_checks
    [ "$fail" = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
    exit "$fail"
fi

if [ "${1:-check}" = security ]; then
    echo "unit hardening: scripts/vm-security-check.sh (one place, with a baseline)"
    exit 0
fi

# The automatic restart (T-154, T-159): with an update staged ("check" leaves one), move the clock
# to 03:10 tomorrow. The service saw its own start as the last activity, so the console counts as
# idle for far more than 30 minutes; at the next tick (within a minute) it announces the restart
# (`restart_at`, 120 s ahead). The script calls it off with a ReportActivity as ruya-shell, checks
# that nothing follows, moves the clock 31 minutes on, and then lets the second announcement run
# out: the service runs `systemctl reboot`. QEMU runs with -no-reboot, so the VM ends here: the host
# sees the SSH connection drop and QEMU exit, and a cold start boots the staged version.
if [ "${1:-check}" = reboot ]; then
    [ "$(field state)" = staged ] || { echo "FAIL: no staged update (run check first)"; exit 1; }
    [ "$(field auto_restart)" = true ] || { echo "FAIL: auto_restart is off"; exit 1; }
    # T-159: the restart is announced first (restart_at = now + 120 s); input calls it off; only
    # a second quiet stretch ends in the reboot.
    wait_restart_at() { # wait_restart_at <nonzero|zero> <seconds>
        local i=0
        while [ "$i" -lt "$2" ]; do
            if [ "$1" = nonzero ]; then [ "$(field restart_at)" != 0 ] && return 0
            else [ "$(field restart_at)" = 0 ] && return 0; fi
            sleep 2; i=$((i + 2))
        done
        return 1
    }
    timedatectl set-ntp false 2>/dev/null || true
    target="$(date -d 'tomorrow 03:10' '+%Y-%m-%d %H:%M:%S')"
    echo "setting the clock to $target (zone $(date +%Z))"
    [ "$(field restart_at)" = 0 ] && ok "no restart announced before the clock moved" || bad "restart_at is set at 12:00"
    date -s "$target"
    # Run 1: announced within a tick, then called off by a ReportActivity from the shell.
    if wait_restart_at nonzero 90; then
        at="$(field restart_at)"; left=$((at - $(date +%s)))
        ok "restart announced: restart_at in ${left} s (a grace of 120 s, reported at the tick)"
        [ "$left" -le 120 ] && [ "$left" -gt 0 ] && ok "and it lies within the grace period" || bad "restart_at is ${left} s away"
    else
        bad "no restart_at within 90 s of the clock move"; journalctl -u ruya-update --no-pager | tail -5; exit 1
    fi
    runuser -u ruya-shell -- busctl --system call "$svc" "$path" "$ifc" ReportActivity b false >/dev/null 2>&1 \
        && ok "ReportActivity by the shell: answered" || bad "ReportActivity by the shell failed"
    [ "$(field restart_at)" = 0 ] && ok "restart_at cleared at once by the activity" || bad "restart_at still set after ReportActivity"
    echo "waiting 200 s: no restart may follow (the idle time starts over)"
    sleep 200
    [ "$(field restart_at)" = 0 ] && ok "still not announced 200 s later (30 idle minutes needed)" || bad "announced again too soon"
    systemctl is-active --quiet ruya-update && ok "still running, no reboot" || bad "ruya-update is not active"
    # Run 2: 31 minutes later, no activity: announced, then the reboot after the grace period.
    date -s "+31 minutes" >/dev/null
    wait_restart_at nonzero 90 && ok "announced again after 30 more idle minutes" || { bad "not announced after 31 idle minutes"; exit 1; }
    echo "no activity; waiting for the restart (up to 240 s)"
    sleep 240
    echo "FAIL: still running 240 s after the announcement"
    journalctl -u ruya-update --no-pager | tail -5
    exit 1
fi

systemctl is-active --quiet ruya-update && ok "ruya-update is active" || bad "ruya-update is not active"
current="$(field current)"
[ -n "$current" ] && ok "current version over the bus: $current" || bad "no current version"
echo "channel: $(field channel), state: $(field state), staged: '$(field staged)', rollback_available: $(field rollback_available)"
[ "$(field state)" = idle ] && ok "idle at start" || echo "NOTE: state is $(field state), not idle (a restart is pending?)"

# A start-up scheduled check (T-154) may still run, and one that finds an update downloads it:
# Check and Download answer `busy` until then (T-160 review). Wait for it first.
wait_state checking 120; wait_state downloading 900
prestaged=no
if [ "$(field state)" = staged ]; then
    prestaged=yes
    echo "NOTE: the scheduled check at start already found and staged an update"
fi

# Check against the dev registry.
reply="$(call Check)"
[ "$reply" = ok ] && ok "Check started" || bad "Check did not answer ok (answered '$reply', state $(field state))"
[ "$(call Check)" = busy ] && ok "second Check while running: busy" || echo "NOTE: the check was already over before the second call"
wait_state checking 120 && ok "check finished: state $(field state)" || bad "check still running after 120 s"
available="$(field available)"
if [ -n "$available" ]; then
    ok "newer image found: $available"
else
    bad "no newer image found (state $(field state), error '$(field error)')"
fi
[ "$(field last_check)" != 0 ] && ok "last_check set" || bad "last_check is 0"
[ "$(field restart_at)" = 0 ] && ok "restart_at is 0 (no restart announced)" || bad "restart_at is $(field restart_at) before any restart rule held"

# Download stages it.
reply="$(call Download)"
if [ "$reply" = ok ]; then
    ok "Download started"
elif [ "$prestaged" = yes ]; then
    echo "NOTE: Download answered '$reply' with the update already staged by the scheduled run"
else
    bad "Download did not answer ok (answered '$reply', state $(field state))"
fi
wait_state downloading 900 && ok "download finished: state $(field state)" || bad "download still running after 900 s"
[ "$(field state)" = staged ] && ok "state staged" || bad "state is $(field state), error '$(field error)'"
staged="$(field staged)"
[ -n "$staged" ] && ok "staged version: $staged" || bad "staged is empty"
if bootc status --json | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)['status']['staged'] else 1)"; then
    ok "bootc status agrees: a staged deployment exists"
else
    bad "bootc status has no staged deployment"
fi

# A caller that is not an admin: ruya-shell with no admin profile active.
out="$(runuser -u ruya-shell -- busctl --system call "$svc" "$path" "$ifc" Rollback 2>&1)"
echo "$out" | grep -q '"forbidden"' && ok "Rollback by the shell without an admin profile: forbidden" || bad "Rollback by the shell answered: $out"
out="$(runuser -u ruya-shell -- busctl --system call "$svc" "$path" "$ifc" SetChannel s beta 2>&1)"
echo "$out" | grep -q '"forbidden"' && ok "SetChannel by the shell without an admin profile: forbidden" || bad "SetChannel by the shell answered: $out"
# Another user is refused by the bus policy.
if runuser -u nobody -- busctl --system call "$svc" "$path" "$ifc" GetStatus >/dev/null 2>&1; then
    bad "user nobody could call Update1"
else
    ok "user nobody refused by the bus policy"
fi
settings_checks
# A name that is no channel is refused (as root, so it is the value, not the caller).
[ "$(call SetChannel s nightly)" = invalid ] && ok "SetChannel nightly: invalid" || bad "SetChannel nightly not invalid"

[ "$fail" = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
exit "$fail"
