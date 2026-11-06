#!/usr/bin/env bash
# Test member lint for CI (T-189): the same two checks as scripts/lint-test-members.ps1, which
# dev.ps1 runs (read its header for the why). Linux CI has no pwsh in the Fedora container.
#
#   scripts/lint-test-members.sh <ruyashell.rsp> [qmllint] [test dir]
#
# 1. qmllint over the tests in the shell's module context: any warning fails (a read of a member
#    QML cannot see is `undefined` and the assertion proves nothing).
# 2. A canary read of a missing member, planted in a copy of every test, must be reported for
#    every file; if not, qmllint went blind on that file (a local declared inside a nested
#    function) and its member reads are unchecked.
# Run from the repository root.
set -u
rsp=${1:?usage: lint-test-members.sh <ruyashell.rsp> [qmllint] [test dir]}
qmllint=${2:-qmllint}
tests=${3:-shell/tests}
canary=ruyaCanaryNoSuchMember
work=$(mktemp -d "./.lint-test-members.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail=0

# Option lines of the response file (not its list of shell sources).
grep -v '\.qml$' "$rsp" > "$work/opts.rsp"

# 1. The tests as they are. --max-warnings 0: without it qmllint exits 0 on warnings.
{ cat "$work/opts.rsp"; ls "$tests"/*.qml; } > "$work/tests.rsp"
if ! "$qmllint" --max-warnings 0 --unqualified disable "@$work/tests.rsp"; then
    echo "A test reads something QML cannot see: it is 'undefined' at run time and the assertion proves nothing."
    echo "Expose the member (Q_PROPERTY / Q_INVOKABLE) or fix its name; type 'property Shell shell'. See shell/CLAUDE.md, Tests."
    fail=1
fi

# 2. The canary, after the first `name:` line (the TestCase's) of every test.
mkdir "$work/canary"
for f in "$tests"/*.qml; do
    awk -v c="$canary" '{ print } !d && /^[ ]+name:[ ]*"/ { print "        function ruya_canary() { return Storage." c " }"; d = 1 }' "$f" > "$work/canary/$(basename "$f")"
done
{ cat "$work/opts.rsp"; ls "$work"/canary/*.qml; } > "$work/canary.rsp"
out=$("$qmllint" --max-warnings 0 --unqualified disable "@$work/canary.rsp" 2>&1)
for f in "$tests"/*.qml; do
    b=$(basename "$f")
    if ! printf '%s\n' "$out" | grep -q "/$b:.*$canary"; then
        echo "$b: qmllint does not check member reads in this file (a canary read of a missing member was not reported)."
        echo "  Usual cause: a local (const, let, for-of) declared inside a nested function or block-bodied arrow; lift it to a top-level function of the TestCase."
        fail=1
    fi
done
exit $fail
