#!/usr/bin/env bash
# RUY-544: reproduce CI's `shell` job (.github/workflows/ci.yml) locally: Fedora 44 in podman, the same
# dnf line, build, qmllint --max-warnings 0, the test member lint and the offscreen Qt Quick tests.
# Windows' Qt and fonts differ from Fedora's (a 1 px font height, a qmllint warning only Fedora raises),
# so a shell change that passes dev.ps1 can still turn CI red; run this before handing over.
#
# Run from WSL, at the repository root (or a worktree):   bash scripts/ci-shell-linux.sh [--cold]
# Warm cache (RUY-549): the dnf packages live in the podman image ruya-ci-shell:<hash of the Containerfile
# below> (rebuilt only when that text, e.g. the dnf line, changes) and the CMake build directory in the
# podman volume ruya-ci-shell-build (never in the repo), so a run after a one-file change only recompiles
# that file. --cold drops both first. The summary says cold or warm and the minutes. A passing run writes
# output/last-green-linux.txt (commit, tree, time) for push-main.ps1, which runs this script once per push
# when shell/**, ci.yml or this script changed since that commit. The commit and tree come from
# RUYA_CI_COMMIT / RUYA_CI_TREE (push-main.ps1 sets them; git cannot read a Windows worktree from WSL), else
# from `git` here; with neither, no marker is written.
# Exit codes: 0 passed, 10 a CI step is red, 3 an image build runs (WSL is shared), 4 the image build failed,
# 5 podman is missing; push-main.ps1 refuses the push only on 10.
# Only the source goes into the container (a tar without .git, services/target, output and shell/build*; the
# size is in the summary); nothing is written to the repo except output/ci-shell-linux*. output/ci-shell-linux.log
# is the container's stdout (the STEP lines and the tail of a failing step); the whole log of each step
# (image, build, qmllint, members, tests) is in output/ci-shell-linux-logs/. The summary on stdout is at most 15 lines. Exit 0 only when everything passed.
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
log="$repo/output/ci-shell-linux.log"
mkdir -p "$repo/output"
logs="$repo/output/ci-shell-linux-logs"
rm -rf "$logs"; mkdir -p "$logs"
src=$(mktemp /tmp/ci-shell-src.XXXXXX)
ctx=$(mktemp -d /tmp/ci-shell-ctx.XXXXXX)
trap 'rm -rf "$src" "$ctx"' EXIT
# Keep the dnf line equal to ci.yml's "Install Qt" step (scripts/lint-ci-lines.ps1 compares them).
read -r -d '' cfile <<'EOS'
FROM registry.fedoraproject.org/fedora:44
RUN dnf -y install --setopt=install_weak_deps=False cmake ninja-build gcc-c++ qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qttools-devel qt6-linguist qt6-qtshadertools-devel qt6-qtbase-private-devel qt6-qtwayland-devel findutils gawk
EOS
read -r -d '' inner <<'EOS'
set -u
mkdir -p /work && cd /work && tar -xf /src.tar
cmake -S shell -B shell/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DRUYA_COMPOSITOR=ON -DRUYA_SOUNDS_RESOURCE=ON >/logs/build.log 2>&1 && cmake --build shell/build >>/logs/build.log 2>&1 || { tail -30 /logs/build.log; echo "STEP build: FAIL"; exit 10; }
echo "STEP build: ok"
if /usr/lib64/qt6/bin/qmllint --max-warnings 0 @shell/build/.rcc/qmllint/ruyashell.rsp >/logs/qmllint.log 2>&1; then echo "STEP qmllint: ok"
else tail -30 /logs/qmllint.log; echo "STEP qmllint: FAIL"; exit 10; fi
if bash scripts/lint-test-members.sh shell/build/.rcc/qmllint/ruyashell.rsp /usr/lib64/qt6/bin/qmllint >/logs/members.log 2>&1; then echo "STEP test member lint: ok"
else tail -30 /logs/members.log; echo "STEP test member lint: FAIL"; exit 10; fi
export QT_QPA_PLATFORM=offscreen
if bash scripts/run-qml-tests.sh shell/build/tst_ruyashell 3 shell/build/qmltest >/logs/tests.log 2>&1; then echo "STEP qml tests: ok"; tail -3 /logs/tests.log
else tail -40 /logs/tests.log; echo "STEP qml tests: FAIL"; exit 10; fi
EOS

command -v podman >/dev/null 2>&1 || { echo "CI-SHELL-LINUX: podman is not available"; exit 5; }
if pgrep -f "podman build" >/dev/null 2>&1; then echo "CI-SHELL-LINUX: a podman image build runs in this WSL; try again when it ends"; exit 3; fi
started=$SECONDS
imgtag="ruya-ci-shell:$(printf '%s' "$cfile" | sha256sum | cut -c1-12)"
vol=ruya-ci-shell-build
if [ "${1:-}" = "--cold" ]; then podman volume rm -f "$vol" >/dev/null 2>&1; podman rmi -f "$imgtag" >/dev/null 2>&1; fi
mode=warm
podman image exists "$imgtag" || mode=cold
podman volume exists "$vol" || { mode=cold; podman volume create "$vol" >/dev/null; }
if [ "$mode" = cold ] && ! podman image exists "$imgtag"; then
  # Older tags of this image are dropped so the cache does not grow with every dnf change.
  podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/ruya-ci-shell:' | xargs -r podman rmi -f >/dev/null 2>&1
  printf '%s\n' "$cfile" | podman build -t "$imgtag" -f - "$ctx" >"$logs/image.log" 2>&1 \
    || { tail -9 "$logs/image.log"; echo "CI-SHELL-LINUX: the image build failed (step logs: $logs)"; exit 4; }
fi

tar -C "$repo" --exclude=./.git --exclude=./services/target --exclude=./output --exclude=./.claude/worktrees --exclude='./shell/build*' -cf "$src" .
size=$(du -h "$src" | cut -f1)
podman run --rm -v "$src":/src.tar:ro -v "$logs":/logs -v "$vol":/work/shell/build "$imgtag" bash -c "$inner" >"$log" 2>&1
code=$?
minutes=$(( (SECONDS - started + 30) / 60 ))
# Summary: the STEP lines and, on a failure, the last lines before the failing STEP (<= 15 lines in all).
echo "source copied into the container: $size; $mode run, $minutes min"
grep -a '^STEP ' "$log"
if [ "$code" -ne 0 ]; then
  grep -av '^STEP ' "$log" | tail -9
  echo "CI-SHELL-LINUX: FAILED (step logs: $logs)"
  [ "$code" -eq 10 ] || code=4
  exit "$code"
fi
grep -a -i 'totals' "$log" | tail -3
commit=${RUYA_CI_COMMIT:-$(git -C "$repo" rev-parse HEAD 2>/dev/null)}
tree=${RUYA_CI_TREE:-$(git -C "$repo" rev-parse 'HEAD^{tree}' 2>/dev/null)}
if [ -z "${RUYA_CI_COMMIT:-}" ] && [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then commit=""; fi
if [ -n "$commit" ]; then
  printf 'commit %s\ntree %s\ntime %s\n' "$commit" "${tree:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$repo/output/last-green-linux.txt"
  echo "marker: output/last-green-linux.txt (${commit:0:10})"
else
  echo "marker: not written (no clean git commit known here; push-main.ps1 passes it)"
fi
echo "CI-SHELL-LINUX: PASSED ($mode, $minutes min)"
exit 0
