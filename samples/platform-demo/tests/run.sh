#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
#
# `make test`: platform-demo with no Platform service at all, then against the developer mock
# (ruya-platform-mock), on a private bus that dbus-run-session starts and ends. The mock is
# $RUYA_PLATFORM_MOCK, else the one cargo built in this repository:
#     (cd services && cargo build -p ruya-platform --bin ruya-platform-mock)
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/../.." && pwd)
mock=${RUYA_PLATFORM_MOCK:-${CARGO_TARGET_DIR:-$repo/services/target}/debug/ruya-platform-mock}

fail() {
    echo "platform-demo test: FAILED: $*" >&2
    exit 1
}

[ -x "$mock" ] || fail "no Platform mock at $mock: build it with \
'(cd services && cargo build -p ruya-platform --bin ruya-platform-mock)' or set RUYA_PLATFORM_MOCK"
command -v dbus-run-session >/dev/null 2>&1 || fail "dbus-run-session not found \
(Fedora: dnf install dbus-daemon; Debian and Ubuntu: apt install dbus-daemon)"

exec dbus-run-session -- sh "$here/tests/session.sh" "$here" "$mock"
