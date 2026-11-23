#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
#
# The steps of `make test`, inside the private bus of tests/run.sh: session.sh <sample> <mock>.
# The demo uses the system bus as on a console; here that is the private bus.
set -eu

here=$1
mock=$2
demo="$here/platform-demo"
work=$(mktemp -d)
mock_pid=
demo_pid=
cleanup() {
    [ -z "$demo_pid" ] || kill "$demo_pid" 2>/dev/null || true
    [ -z "$mock_pid" ] || kill "$mock_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
export XDG_DATA_HOME="$work/data"
mkdir -p "$XDG_DATA_HOME"

fail() {
    echo "platform-demo test: FAILED: $*" >&2
    for log in "$work"/*.log; do
        [ -f "$log" ] || continue
        echo "--- $(basename "$log")" >&2
        cat "$log" >&2
    done
    exit 1
}

# wait_for <log> <text>: until the text is in the log, at most 10 s.
wait_for() {
    i=0
    while ! grep -qF -- "$2" "$work/$1" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -le 100 ] || fail "'$2' did not appear in $1 within 10 s"
        sleep 0.1
    done
}

# 1. No service on the bus: the demo runs on without lifecycle events.
"$demo" --frames 5 > "$work/alone.log" 2>&1 || fail "the demo failed with no service"
wait_for alone.log "no Platform service: running without lifecycle events"
wait_for alone.log "saved"

# 2. The mock on the bus: the demo registers.
"$mock" --scenario "$here/tests/scenario.json" --state "$work/state" 2> "$work/mock.log" &
mock_pid=$!
"$mock" wait 10 2>> "$work/mock.log" || fail "the mock did not start"
"$demo" > "$work/demo.log" 2>&1 &
demo_pid=$!
wait_for demo.log "Register: ok"

# 3. The clock gap is the primary path: stopped for 1.5 s, as a freeze would.
kill -STOP "$demo_pid"
sleep 1.5
kill -CONT "$demo_pid"
wait_for demo.log "we were frozen"

# 4. Resume carries the frozen time.
[ "$("$mock" fire resume 1500)" = ok ] || fail "Fire resume was not ok"
wait_for demo.log "Resume: in front again, frozen for 1500 ms"

# 5. Stopping: the demo saves, then SaveDone ends the wait with "saved", and it exits 0.
answer=$("$mock" fire stopping 5000)
[ "$answer" = saved ] || fail "Fire stopping answered '$answer', not 'saved'"
code=0
wait "$demo_pid" || code=$?
demo_pid=
[ "$code" -eq 0 ] || fail "the demo exited $code"
wait_for demo.log "SaveDone: ok"
[ -s "$XDG_DATA_HOME/platform-demo.save" ] || fail "no save was written"

echo "platform-demo test: ok"
