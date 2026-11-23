#!/bin/bash
# SPDX-License-Identifier: MIT
#
# CI "samples" job (RUY-822): compile both .play samples, build each .play.zip with the real
# ruya-pack and inspect it; then (RUY-158) the Platform conformance run against the developer mock
# with its self-test, platform-demo's `make test` against the mock, and the same test with no mock
# (it must fail and say why). Run it in Fedora 44 (the CI container, or WSL: FedoraLinux-44):
#
#     bash scripts/ci-samples-linux.sh
#
# It installs nothing. Packages (the same line as the `samples` job in .github/workflows/ci.yml):
#     gcc SDL3-devel pkgconf-pkg-config mingw64-gcc mingw32-gcc cargo rust findutils make
#     systemd-devel dbus-daemon
# CARGO_TARGET_DIR overrides where ruya-pack, the mock and the runner are built (default:
# services/target-samples).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/lib-samples.sh"

samples_build_pack "$root" || exit 1

# Warnings fail here; a developer's plain ./build.sh keeps its defaults.
export CC="${CC:-cc} -Werror"
# The Windows build.sh quotes $MINGW_CC and $MINGW_CC32 as one word each, so -Werror goes in a tiny
# wrapper per compiler.
wrap=$(mktemp -d)
# The build outputs go on exit (lib-samples.sh).
clean() {
    rm -rf "$wrap"
    samples_clean_outputs "$root" hello-play-native hello-play-wine
}
trap clean EXIT
for w in "mingw-gcc:${MINGW_CC:-x86_64-w64-mingw32-gcc}" "mingw32-gcc:${MINGW_CC32:-i686-w64-mingw32-gcc}"; do
    printf '#!/bin/sh
exec %s -Werror "$@"
' "${w#*:}" > "$wrap/${w%%:*}"
    chmod +x "$wrap/${w%%:*}"
done
export MINGW_CC="$wrap/mingw-gcc" MINGW_CC32="$wrap/mingw32-gcc"

fail=0
summary=""
for s in hello-play-native hello-play-wine; do
    dir="$root/samples/$s"
    zip="$dir/$s.play.zip"
    rm -f "$zip"
    # The build scripts exit 0 without ruya-pack; the zip check below catches that.
    if ! sh "$dir/build.sh"; then
        summary="$summary$s: FAILED (build.sh)\n"; fail=1; continue
    fi
    if [ ! -s "$zip" ]; then
        summary="$summary$s: FAILED (no zip)\n"; fail=1; continue
    fi
    summary="$summary$s: $(wc -c < "$zip") bytes, inspect ok\n"
done

# RUY-158: conformance.sh builds the mock into $CARGO_TARGET_DIR (lib-samples.sh exported it),
# where platform-demo's test finds it.
if bash "$root/scripts/conformance.sh" --self-test; then
    summary="${summary}conformance: passed, self-test ok\n"
else
    summary="${summary}conformance: FAILED\n"; fail=1
fi
if make -C "$root/samples/platform-demo" test; then
    summary="${summary}platform-demo: make test ok\n"
else
    summary="${summary}platform-demo: FAILED (make test)\n"; fail=1
fi
# With no mock the test must fail and say what is missing.
if absent=$(RUYA_PLATFORM_MOCK=/nonexistent/ruya-platform-mock make -C "$root/samples/platform-demo" test 2>&1); then
    summary="${summary}platform-demo: FAILED (make test passed with no mock)\n"; fail=1
elif printf '%s\n' "$absent" | grep -q "no Platform mock at /nonexistent/ruya-platform-mock"; then
    summary="${summary}platform-demo: with no mock it fails and says so\n"
else
    summary="${summary}platform-demo: FAILED (no readable message with no mock)\n"; fail=1
    printf '%s\n' "$absent"
fi
make -C "$root/samples/platform-demo" clean > /dev/null

echo "== ci-samples summary =="
printf '%b' "$summary"
exit $fail
