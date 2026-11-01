#!/usr/bin/env bash
# Checks ruya-update (org.ruyaos.Update1, T-151) inside a running VM, as root. Prepare: the VM
# tracks <wsl-ip>:5000/ruyaos:stable (bootc switch, then reboot) and the registry holds a NEWER
# image under that tag (docs/dev-setup.md, "Update check"). Copy and run:
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-update-check.sh root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-update-check.sh [check|security]
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
field() { status | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['$1']['data'])"; }
call() { busctl --system call "$svc" "$path" "$ifc" "$@" | sed 's/^s "\(.*\)"$/\1/'; }
wait_state() { # wait_state <not-this-state> <seconds>
    local i=0
    while [ "$i" -lt "$2" ]; do
        [ "$(field state)" != "$1" ] && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

if [ "${1:-check}" = security ]; then
    systemd-analyze security ruya-update
    exit 0
fi

systemctl is-active --quiet ruya-update && ok "ruya-update is active" || bad "ruya-update is not active"
current="$(field current)"
[ -n "$current" ] && ok "current version over the bus: $current" || bad "no current version"
echo "channel: $(field channel), state: $(field state), staged: '$(field staged)', rollback_available: $(field rollback_available)"
[ "$(field state)" = idle ] && ok "idle at start" || echo "NOTE: state is $(field state), not idle (a restart is pending?)"

# Check against the dev registry.
[ "$(call Check)" = ok ] && ok "Check started" || bad "Check did not answer ok"
[ "$(call Check)" = busy ] && ok "second Check while running: busy" || echo "NOTE: the check was already over before the second call"
wait_state checking 120 && ok "check finished: state $(field state)" || bad "check still running after 120 s"
available="$(field available)"
if [ -n "$available" ]; then
    ok "newer image found: $available"
else
    bad "no newer image found (state $(field state), error '$(field error)')"
fi
[ "$(field last_check)" != 0 ] && ok "last_check set" || bad "last_check is 0"

# Download stages it.
[ "$(call Download)" = ok ] && ok "Download started" || bad "Download did not answer ok"
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
# A name that is no channel is refused (as root, so it is the value, not the caller).
[ "$(call SetChannel s nightly)" = invalid ] && ok "SetChannel nightly: invalid" || bad "SetChannel nightly not invalid"

[ "$fail" = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
exit "$fail"
