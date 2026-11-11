#!/bin/bash
# T-463: the offscreen Qt Quick tests, one process per test file (the runner takes one -input), N of
# them at a time, biggest file first, each with its own log. CI's shell job runs this; dev.ps1 does the
# same on Windows (Invoke-QmlShards). A file whose process exits non-zero, ends without a "Totals" line
# (a crash) or runs longer than RUYA_QML_TIMEOUT seconds (default 600) fails the run and its log is named.
# Usage: scripts/run-qml-tests.sh <tst_ruyashell> <shards> <logdir> [testdir]   (testdir: shell/tests)
# Needs QT_QPA_PLATFORM=offscreen in the environment, as the gate sets it.
set -u
exe="${1:?usage: run-qml-tests.sh <tst_ruyashell> <shards> <logdir> [testdir]}"
shards="${2:-3}"
logdir="${3:?log directory}"
testdir="${4:-shell/tests}"
mkdir -p "$logdir"
rm -f "$logdir"/*.txt "$logdir"/*.out "$logdir"/*.err

run_one() {
  local f="$1" base log code
  base=$(basename "$f" .qml)
  log="$LOGDIR/$base.txt"
  timeout "${RUYA_QML_TIMEOUT:-600}" "$EXE" -o "$log,txt" -input "$f" >"$log.out" 2>"$log.err"
  code=$?
  if ! grep -aq '^Totals:' "$log" 2>/dev/null; then
    echo "SHARD FAILED: $base: crashed or hung (exit code $code, no Totals line) - log $log"
    return 1
  elif [ "$code" -ne 0 ]; then
    echo "SHARD FAILED: $base: failed (exit code $code) - log $log"
    grep -a '^FAIL\|^XPASS\|failure location' "$log" | sed "s/^/    $base: /"
    return 1
  fi
}
export -f run_one
export EXE="$exe" LOGDIR="$logdir"

files=$(ls -S "$testdir"/tst_*.qml)
count=$(echo "$files" | wc -l)
start=$(date +%s)
echo "$files" | xargs -P "$shards" -I{} bash -c 'run_one {}' > "$logdir/shards.out"
cat "$logdir/shards.out"
bad=$(grep -c '^SHARD FAILED' "$logdir/shards.out")
elapsed=$(( $(date +%s) - start ))

done_files=$(ls "$logdir"/*.txt 2>/dev/null | wc -l)
grep -ah '^Totals:' "$logdir"/*.txt | awk -v n="$done_files" -v s="$shards" -v t="$elapsed" '
  { p += $2; f += $4; k += $6 }
  END { printf "Totals: %d passed, %d failed, %d skipped in %d files, %d at a time, %d s\n", p, f, k, n, s, t }'
if [ "$bad" -ne 0 ] || [ "$done_files" -ne "$count" ]; then
  echo "run-qml-tests: FAILED ($bad bad file(s), $done_files of $count logs)"
  exit 1
fi
echo "run-qml-tests: ok"
