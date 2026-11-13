#!/usr/bin/env bash
# RUY-544: reproduce CI's `shell` job (.github/workflows/ci.yml) locally: Fedora 44 in podman, the same
# dnf line, build, qmllint --max-warnings 0, the test member lint and the offscreen Qt Quick tests.
# Windows' Qt and fonts differ from Fedora's (a 1 px font height, a qmllint warning only Fedora raises),
# so a shell change that passes dev.ps1 can still turn CI red; run this before handing over.
#
# Run from WSL, at the repository root (or a worktree):   bash scripts/ci-shell-linux.sh
# Only the source goes into the container (a tar without .git, services/target, output and shell/build*; the
# size is in the summary); nothing is written to the repo except output/ci-shell-linux*. output/ci-shell-linux.log
# is the container's stdout (the STEP lines and the tail of a failing step); the whole log of each step
# (dnf, build, qmllint, members, tests) is in output/ci-shell-linux-logs/. The summary on stdout is at most 15 lines. Exit 0 only when everything passed.
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
log="$repo/output/ci-shell-linux.log"
mkdir -p "$repo/output"
logs="$repo/output/ci-shell-linux-logs"
rm -rf "$logs"; mkdir -p "$logs"
src=$(mktemp /tmp/ci-shell-src.XXXXXX)
trap 'rm -f "$src"' EXIT
tar -C "$repo" --exclude=./.git --exclude=./services/target --exclude=./output --exclude=./.claude/worktrees --exclude='./shell/build*' -cf "$src" .
size=$(du -h "$src" | cut -f1)

# Keep this dnf line equal to ci.yml's "Install Qt" step.
read -r -d '' inner <<'EOS'
set -u
dnf -y install --setopt=install_weak_deps=False cmake ninja-build gcc-c++ qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qttools-devel qt6-linguist qt6-qtshadertools-devel qt6-qtbase-private-devel findutils gawk >/logs/dnf.log 2>&1 || { tail -5 /logs/dnf.log; echo "STEP dnf: FAIL"; exit 1; }
echo "STEP dnf: ok"
mkdir /work && cd /work && tar -xf /src.tar
cmake -S shell -B shell/build -G Ninja -DCMAKE_BUILD_TYPE=Release >/logs/build.log 2>&1 && cmake --build shell/build >>/logs/build.log 2>&1 || { tail -30 /logs/build.log; echo "STEP build: FAIL"; exit 1; }
echo "STEP build: ok"
if /usr/lib64/qt6/bin/qmllint --max-warnings 0 @shell/build/.rcc/qmllint/ruyashell.rsp >/logs/qmllint.log 2>&1; then echo "STEP qmllint: ok"
else tail -30 /logs/qmllint.log; echo "STEP qmllint: FAIL"; exit 1; fi
if bash scripts/lint-test-members.sh shell/build/.rcc/qmllint/ruyashell.rsp /usr/lib64/qt6/bin/qmllint >/logs/members.log 2>&1; then echo "STEP test member lint: ok"
else tail -30 /logs/members.log; echo "STEP test member lint: FAIL"; exit 1; fi
export QT_QPA_PLATFORM=offscreen
if bash scripts/run-qml-tests.sh shell/build/tst_ruyashell 3 shell/build/qmltest >/logs/tests.log 2>&1; then echo "STEP qml tests: ok"; tail -3 /logs/tests.log
else tail -40 /logs/tests.log; echo "STEP qml tests: FAIL"; exit 1; fi
EOS

podman run --rm -v "$src":/src.tar:ro -v "$logs":/logs registry.fedoraproject.org/fedora:44 bash -c "$inner" >"$log" 2>&1
code=$?
# Summary: the STEP lines and, on a failure, the last lines before the failing STEP (<= 15 lines in all).
echo "source copied into the container: $size"
grep -a '^STEP ' "$log"
if [ "$code" -ne 0 ]; then
  grep -av '^STEP ' "$log" | tail -9
  echo "CI-SHELL-LINUX: FAILED (step logs: $logs)"
else
  grep -a -i 'totals' "$log" | tail -3
  echo "CI-SHELL-LINUX: PASSED"
fi
exit "$code"
