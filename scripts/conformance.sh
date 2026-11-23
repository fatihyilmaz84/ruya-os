#!/bin/bash
# SPDX-License-Identifier: MIT
#
# The Platform API conformance run (RUY-158, ADR-022, ADR-031): ruya-platform-conformance against
# the developer mock (ruya-platform-mock, the service's own code with a scenario identity) on a
# private session bus. Linux only (the mock reads /proc and needs a bus that passes ProcessFD,
# as Fedora 44's do); builds both binaries with cargo first.
#
#     bash scripts/conformance.sh [--apis <apis.json>]    prints PASS/FAIL per case, CONFORMANCE: n/m
#     bash scripts/conformance.sh --self-test             also: a mock made to answer a wrong
#                                                         status must fail the run
#
# Exit 0 passed, 1 failed, 2 not run (a missing tool). `--apis` (the apis.json lint-dev-docs.ps1
# writes) adds the coverage check: every public Platform1 element has a case. The run on a real
# console (the runner's apps as Flatpak peers, the events through Manage.NotifyLifecycle) is planned.
# CARGO_TARGET_DIR overrides where the binaries are built (default: services/target).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
xml="$root/api/dbus/org.ruyaos.Platform1.xml"

if [ "${1:-}" = "--inner" ]; then
    # Inside dbus-run-session: conformance.sh --inner <bin dir> <self-test 0|1> [runner args...]
    bin=$2
    self_test=$3
    shift 3
    work=$(mktemp -d)
    mock_pid=
    stop_mock() {
        if [ -n "$mock_pid" ]; then
            kill "$mock_pid" 2>/dev/null || true
            wait "$mock_pid" 2>/dev/null || true
        fi
        mock_pid=
    }
    trap 'stop_mock; rm -rf "$work"' EXIT
    "$bin/ruya-platform-conformance" scenario > "$work/scenario.json"

    # start_mock <log>: a fresh mock (no choices, no faults), ready on the bus.
    start_mock() {
        rm -rf "$work/state"
        "$bin/ruya-platform-mock" --scenario "$work/scenario.json" --state "$work/state" 2> "$work/$1" &
        mock_pid=$!
        if ! "$bin/ruya-platform-mock" wait 10 2>> "$work/$1"; then
            echo "conformance: the mock did not start:" >&2
            cat "$work/$1" >&2
            exit 1
        fi
    }

    start_mock mock.log
    code=0
    "$bin/ruya-platform-conformance" run --xml "$xml" "$@" || code=$?
    stop_mock
    if [ "$code" -ne 0 ]; then
        echo "--- the mock's log" >&2
        cat "$work/mock.log" >&2
        exit "$code"
    fi
    [ "$self_test" = 1 ] || exit 0

    # Self-test: Register made to answer "not-allowed"; the run must fail and say where.
    start_mock fault.log
    "$bin/ruya-platform-mock" fault Register not-allowed > /dev/null
    out=$("$bin/ruya-platform-conformance" run --xml "$xml" "$@" 2>&1) && fcode=0 || fcode=$?
    stop_mock
    if [ "$fcode" -ne 1 ] || ! printf '%s\n' "$out" | grep -q '^FAIL register-ok-and-again: .*answered "not-allowed", expected "ok"'; then
        echo "conformance self-test: FAILED: a faulted Register did not fail the run (exit $fcode):" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    echo "conformance self-test: a faulted Register fails the run ($(printf '%s\n' "$out" | grep '^CONFORMANCE:'))"
    exit 0
fi

self_test=0
args=()
while [ $# -gt 0 ]; do
    case $1 in
        --self-test) self_test=1 ;;
        --apis) args+=(--apis "$2"); shift ;;
        *) echo "usage: scripts/conformance.sh [--apis <apis.json>] [--self-test]" >&2; exit 1 ;;
    esac
    shift
done

for tool in cargo dbus-run-session; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "CONFORMANCE: NOT RUN ($tool not found; Fedora: dnf install cargo dbus-daemon)"
        exit 2
    fi
done
target=${CARGO_TARGET_DIR:-$root/services/target}
(cd "$root/services" && CARGO_TARGET_DIR="$target" cargo build --locked -q -p ruya-platform \
    --features dev-mock --bin ruya-platform-mock --bin ruya-platform-conformance)
exec dbus-run-session -- bash "$0" --inner "$target/debug" "$self_test" "${args[@]}"
