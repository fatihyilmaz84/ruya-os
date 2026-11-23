# Sourced by the scripts that drive the Dell over ssh (dell-hub-check.sh, dell-epp-bench.sh,
# dell-perf-bench.sh); not run on its own. The caller sets HOST before sourcing and, for signin, may
# set RUYA_PIN. The Dell is a test machine (CLAUDE.md).
DELL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSHO="-i $HOME/.ssh/ruyaos_dev -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
r() { ssh $SSHO "root@$HOST" "$@"; }
BUS='runuser -u ruya-shell -- busctl --system'
SESSION="$BUS call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1"
now() { r 'date +%s'; }

# The signed-in profile id ("" when nobody is).
active() { r "$BUS get-property org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ActiveProfile" | sed -n 's/^s "\(.*\)"/\1/p'; }

# Signs a profile in over D-Bus: the first one with RUYA_PIN, else the first one with no PIN.
signin() {
    local id pin
    if [ -n "${RUYA_PIN:-}" ]; then
        id=$(r "$BUS --json=short call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles" | grep -o '\["[^"]*"' | head -1 | tr -d '[""')
        pin="$RUYA_PIN"
    else
        id=$(r "$BUS --json=short call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles" | grep -o '\["[^"]*","[^"]*","[^"]*","[^"]*",false' | head -1 | cut -d'"' -f2)
        pin=""
    fi
    [ -n "$id" ] || return 1
    r "$BUS call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 SwitchTo ss $id '$pin'" | grep -q '"ok"' || return 1
    sleep 3
}

# Stops every running app (Home).
stop_apps() {
    local i
    for i in $(r "$BUS --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 ListRunning" | grep -o 'ruya-app-[^"]*service'); do
        r "$SESSION Stop s $i" >/dev/null
    done
}

# shell_cost <seconds>: over that long, prints "<render ms> <cpu ticks> <package W> <package C>": the
# shell's drm render time and CPU ticks (100 is one core), the RAPL package power and the package
# temperature at the end ("-" without a reading). Runs lib/dell-cost.sh on the Dell.
shell_cost() { r "bash -s -- $1" < "$DELL_LIB/dell-cost.sh"; }

# The booted image's version ("" when bootc does not say).
image_version() { r "bootc status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"status\"][\"booted\"][\"image\"][\"version\"])'" 2>/dev/null; }

# RUYA_PERF_LOG=1 for the shell: the compositor's frame meter then logs "perf-frames" four times a
# second. A volatile systemd drop-in in /run: perflog_dropin_add <file> writes it, perflog_dropin_rm
# <file> removes it; the caller restarts ruya-compositor@tty1 (the shell) to take either one.
PERFLOG_DIR=/run/systemd/system/ruya-compositor@tty1.service.d
perflog_dropin_add() { r "mkdir -p $PERFLOG_DIR; printf '[Service]\nEnvironment=RUYA_PERF_LOG=1\n' > $PERFLOG_DIR/$1; systemctl daemon-reload"; }
perflog_dropin_rm() { r "rm -f $PERFLOG_DIR/$1; rmdir $PERFLOG_DIR 2>/dev/null; systemctl daemon-reload"; }
