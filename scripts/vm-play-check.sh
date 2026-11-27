#!/usr/bin/env bash
# modes: asknet bumpbuild bundled bundledpkg bundledver check compat32 generation helper launch launch-windows libprobe lstate modpath offline parse perms pkgid remove removeapp runid signals sysrunner verify winpkg withid
# Checks ruya-play (org.ruyaos.Play1, RUY-829, the lead's run under RUY-100) inside a running VM,
# as root. [RUYA_PIN=<digits>] is the PIN of the profile the launch modes sign in (tried after no PIN,
# before 1234), as for dell-hub-check.sh; it is never printed. Modes:
#   check  (default) every step below
#   asknet host fixtures only: `asknet <in.zip> <out.zip>` copies a package whose play.json asks
#          for network, multiarch and gamemode (`asks_network`, the perms and remove modes use it)
#   withid host fixtures only: `withid <in.zip> <out.zip> <id>` copies a package with the id of its
#          play.json changed (the helper verify and perms use)
#   removeapp `removeapp play.<id>` (RUY-1001): the one way a check removes a .play app: Play1.Remove
#          as an admin, waiting for the job's end, so ruya-play records the uninstall (a bare
#          `flatpak uninstall` leaves the build recorded, and the next install of that build is refused
#          build.not_newer). Exit 0 when the job finishes ok or the app is not installed; vm-library-check.sh
#          calls it, so copy this script next to that one. Every cleanup here goes through it too
#   helper the helper's sandbox only: systemd-analyze security of ruya-play.service and of a probe
#          unit started with the helper's own properties (ruya-play --helper-argv), no network and
#          no write outside its state folder from inside it, reading a USB source and an incoming/
#          file (root 0600) through the passed descriptor, the StateDirectory handover
#   verify RUY-834: install the sample (developer mode, from incoming/), Play1.Verify -> a job that
#          finishes ok; append a byte to one deployed file as root -> invalid-package with
#          package.hash_mismatch (state/jobs); an extra file -> invalid-package; restored -> ok;
#          Verify of an unknown id is unknown-app, of "" invalid
#   perms  RUY-851: a copy of the sample that asks for network, multiarch and gamemode installs
#          unsigned (developer mode, from incoming/); `flatpak info --show-permissions` of the app
#          equals exactly the set 05 section 8 maps those to (no filesystem, no other bus name),
#          and the deployment's share/ruyaos/play/trust.json says format 1, unverified, no signer,
#          no store signature; then (RUY-854) the console's permission list covers the app: Store1
#          GetPermissions (as root, an admin) answers for it right after the install with the network
#          allowed and withdrawable, the sandbox `flatpak run` builds reaches a listener on the
#          host's loopback, WithdrawPermission network is ok and writes `shared=!network;` into the
#          app's override only (`flatpak info --show-metadata`, the deployment's own, is byte for byte
#          what it was before, also after the reset; `--show-permissions` is metadata merged with the
#          override, so it lacks network after the withdrawal, RUY-1002), the next sandbox cannot
#          connect, ResetPermissions removes the override and the connection works again
#   remove RUY-816: install the sample (developer mode, from incoming/), Play1.Remove without
#          admin_approved is forbidden, of "" invalid, of an app that is not play.<id> or not
#          installed unknown-app; with admin_approved a job that finishes ok (kind remove, phase
#          removing in state/jobs): the deployment is gone, Flatpak no longer lists the app, the
#          installed build is forgotten (state/installed.json), a second Remove is unknown-app, the
#          package installs again, and the shell-less cleanup leaves nothing behind. RUY-923: the
#          sample asks for the network; an admin withdraws it (Store1 WithdrawPermission, an override
#          in /var/lib/flatpak/overrides), and the removal drops that override too (`flatpak
#          override --system --show` is empty) so the reinstall starts with nothing withdrawn
#   launch RUY-902 (ADR-037/038): the native sample installed (developer mode, from incoming/) and started as a
#          profile through Session1.Launch (the check makes one when the VM has none, as vm-sample-check.sh
#          does, and removes it again): AppStarted, the save in the app's data folder (plays=1), Stop ends
#          it with AppExited "quit", a second Launch loads the save (plays=2), the launcher wrote its
#          status file (no runner), no init_t AVC denial and no SIGSYS in the journal. SDL runs on its
#          dummy drivers (a flatpak override the check removes again)
#   launch-windows RUY-902: the Windows sample (zip: /root/hello-play-wine.play.zip, built by
#          scripts/play-vm-files.sh) installed as a copy whose command is its 32-bit console program
#          check.exe and which asks for multiarch (nothing else); signed in as the profile, the default
#          routes taken away (the game runs offline; the runtime is installed before that). The launch
#          ends by itself: AppExited code 0, reason "quit"; in the prefix (${prefix}, the Proton
#          prefix under the app's data folder) check.txt says launches=1, pointer_bits=32, wow64=1,
#          network=closed; the launcher's status file says the OS's GE-Proton ran the setup step once;
#          a second Launch of the same profile finds the save (launches=2); the app has no network
#          permission; no init_t AVC denial and no SIGSYS in the journal. The routes come back at exit.
#          RUY-1019 (ADR-040): the sample's programs are in its run.writable folder Program/, so the
#          launcher runs check.exe from the profile's game tree (<data>/.ruya-play/game): the path
#          GetModuleFileNameW gives (module= in check.txt, Z: being /) is in that tree, the file
#          check.exe writes beside itself (beside.txt) is there after each launch and survives the
#          relaunch, the status file records game_build; then the next build of the package (build+1,
#          its check.ini changed: bumpbuild) is installed over it and launched a third time: check.exe
#          reads the new check.ini (edition=2: the file it never changed was replaced), beside.txt
#          says launches=3 (what it wrote was kept) and game_build is the new build
#          RUY-1039: in the app's sandbox, with the runner's files/lib/x86_64-linux-gnu first in
#          LD_LIBRARY_PATH as the proton script has it, libSDL2, libSDL3, libudev, libvulkan, libfreetype,
#          libgnutls and libpulse each load (a child process per library: an abort is a FAIL line); and
#          with a held uinput pad (vm-input-probe.py pad, next to this script) routed by the shell, the
#          winebus winedevice holds the virtual pad's /dev/input/event* during the first launch
#   bundled RUY-1248 (05 section 6.2, the epic's definition of done): which runner a launch uses. The Windows
#          sample (zip: /root/hello-play-wine.play.zip) installed as a copy whose component is `source: newest`
#          with a bundled copy of the OS's family (proton-ge) one version above the image's GE-Proton. The
#          bundled copy is not GE-Proton's 1.5 GiB but a folder of two files: its runner.json and a `proton`
#          script that records its own run (<data>/bundled-runner-ran, one "<version> <verb>" line per call)
#          and then execs the image's GE-Proton, so the launcher really starts the bundled entry and the
#          game really runs. Signed in as the profile, Library1 ResolveRunner and the launcher's status
#          file (runner=<source>/<family>/<version>) say which runner: (1) with no choice the bundled copy
#          (ResolveRunner package and the launch), its script ran for the game; (2) with the profile's choice
#          `System` (Library1 SetRunnerChoice, which ruya-session passes as --runner=system, RUY-904) the
#          image's GE-Proton and the script did not run; (3) the next build of the package with `source:
#          bundled` ignores that choice: ResolveRunner answers the bundled copy as a fallback, the launch
#          uses it and the script ran again. check.txt counts the three launches (launches=3). The profile's
#          choice is put back to package at exit. Needs vm-runner-check.sh next to this script, as launch-windows
#   bundledver host fixtures only: `bundledver <runners dir>` prints the version of the bundled copy:
#          the newest proton-ge below the directory with its last number raised by one (GE-Proton11-13 is GE-Proton11-14)
#   bundledpkg host fixtures only: `bundledpkg <in.zip> <out.zip> <id> <source> <bump> <runners dir>` copies the
#          Windows sample as launch-windows installs it (winpkg) with the component's source set to <source> and
#          the bundled copy above (runner.json, the `proton` script, both in play.files), its build raised by <bump>
#   libprobe host fixtures only: `libprobe <runner root> "<soname>..."` runs the sandbox probe of the library
#          loads in this shell (the fixture puts a python3 shim in PATH)
#   signals host fixtures only: `signals <monitor.log> <member> <app id>` prints one line per such
#          Session1 signal in a `busctl --json=short monitor` log: the instance and the arguments
#          after the app id ("inst" for AppStarted, "inst 0 quit" for AppExited)
#   winpkg host fixtures only: `winpkg <in.zip> <out.zip> <id>` copies a package with the id changed, its
#          command set to ${game}/Program/check.exe and permissions.multiarch true (what launch-windows installs)
#   bumpbuild host fixtures only: `bumpbuild <in.zip> <out.zip> <path> <text>` copies a package as its next
#          build (build+1) with payload/<path> holding <text> and its play.files line updated (size, SHA-256);
#          prints the new build (launch-windows installs it as the update)
#   modpath host fixtures only: `modpath <check.txt>` prints the module= path of check.exe's report as the
#          Unix path Wine maps it to (Z:\a\b is /a/b); nothing and status 1 for another drive or no line
#   lstate host fixtures only: `lstate <state.json>` prints the launcher's status file as
#          "epoch=<n> setup_done=<ids> runner=<source>/<family>/<version>" ("none" for a native game),
#          then " game=<n>" when it records the build of a game tree (game_build, RUY-1019)
#   sysrunner host fixtures only: `sysrunner <runners dir>` prints "<family>/<version>" of the newest
#          proton-ge runner.json below it (the OS's GE-Proton launch-windows expects in the status file);
#          which folder is the newest is `vm-runner-check.sh newest`, so that script must be next to this one
#   compat32 host fixtures only: `compat32 <app id>` prints the Compat.i386 ref of the app's runtime and exits 1
#          when it is not installed (launch-windows FAILs naming it: a 32-bit program needs /lib/ld-linux.so.2)
#   offline host fixtures only: `offline on|off <dir>` takes the default routes away (kept in <dir>) or
#          puts them back; launch-windows uses it around its launches
#   runid  host fixtures only: `runid <id>` prints the id check would use for <id>
#   pkgid  host fixtures only: `pkgid <id> <part>` prints "<id>_<part>" (the one id-suffix rule,
#          RUY-887; vm-library-check.sh asks it for its own id), FAIL when it passes 120 bytes (PLAY_MAX_ID_BYTES)
#   generation host fixtures only: `generation <installed.json> <id> [<n>]` prints the metadata
#          generation recorded for <id> (0 when the entry has none, "none" without an entry), after
#          setting it to <n>. `check` uses it (RUY-900, ADR-038): the install stamps a generation;
#          set back to 0 with the service stopped, the next start commits the app again (log line
#          "recommitted play.<id>", a new commit, the generation stamped, the runners' point in the
#          metadata), and the start after that plans no recommit for it
#   Every mode that installs uses its own package id (RUY-877): "<id>_c<run>" for check (one
#   fresh id per run, RUY-879; its signed-A/B steps need one id within the run, on purpose),
#   "<id>_verify" for verify and "<id>_perms" for perms (pkg_id), written into a copy of the sample's
#   play.json. ruya-play keeps a signer's trust record for an id after an uninstall (05 section
#   9), so a shared id made a later install different-developer. verify and perms install
#   unsigned, so no key record can block their fixed ids; check signs with a new key A each run,
#   so it takes a new id each run and leaves one small trust record behind, by design. The modes
#   pass in any order, and check any number of times, on one VM.
#   parse  host fixtures only (scripts/test-vm-checks.sh): reads busctl --json=short on stdin;
#          `parse status` prints a call's first string, `parse job <id>` the job's state and
#          status, `parse sources` the listed paths, `parse items` Library1's ids; `parse perms`
#          reads Flatpak permission sections instead and prints one sorted line per entry
#          ("[Context] shared=network")
#
# The packages: samples/hello-play-native built as scripts/ci-samples-linux.sh does (RUY-822),
# without its clean-up, and ruya-pack from the same build:
#   scp -P 2222 samples/hello-play-native/hello-play-native.play.zip \
#       services/target-samples/release/ruya-pack scripts/vm-play-check.sh root@127.0.0.1:/root/
#   ssh -p 2222 root@127.0.0.1 bash /root/vm-play-check.sh check /root/hello-play-native.play.zip /root/ruya-pack
# Optional: TESTBIN=<dir> with the Linux test binaries of ruya-play (`cargo test -p ruya-play
# --no-run` on a Linux host: toctou-*, modes-*, jobs-*) runs the Unix-only core tests here too.
#
# From the package the check makes, with ruya-pack and python3: an unsigned copy (the sample), one
# signed by key A, one signed by key B (same id: different-developer), one signed by A with its
# play.json changed after signing (bad-signature) and a zip bomb. They go on a loop vfat image
# mounted at /run/media/ruya-shell/PLAYCHECK nosuid,nodev,noexec (as ruya-devices mounts drives).
# The steps: an unsigned package without developer mode is needs-developer-mode; the tampered one
# is bad-signature; the bomb is refused and the service keeps its PID; the A package installs
# (flatpak list --system, Library1.ListItems, Session1.Launch when a profile exists; the check
# creates none: without one that step is a SKIP with its reason, so create a profile in the shell
# first, or the launch goes uncovered); the B
# package is different-developer; after every refusal staging/ is empty and no new play.* app is
# installed; ListSources lists the drive's packages; a drive mounted without noexec is
# unknown-source; a download in incoming/ inspects. At exit everything is removed again, the app
# through Play1.Remove (`removeapp`).
# JSON is parsed by key, never by key order.
set -u
mode="${1:-check}"
zip="${2:-/root/hello-play-native.play.zip}"
pack="${3:-/root/ruya-pack}"
# launch-windows and bundled run the Windows sample (RUY-902, RUY-1248); every other mode the native one.
if { [ "$mode" = launch-windows ] || [ "$mode" = bundled ]; } && [ -z "${2:-}" ]; then
    zip=/root/hello-play-wine.play.zip
fi
svc=org.ruyaos.Play1
obj=/org/ruyaos/Play1
work=/var/lib/ruya-play-check
usb=/run/media/ruya-shell/PLAYCHECK
loose=/run/media/ruya-shell/PLAYLOOSE
state=/var/lib/ruya-play
# staging/ and inspect/ live on the helpers' mount (RUY-866, 05 section 7.3).
staging=/var/lib/private/ruya-play-work/staging
fail=0
since="$(date '+%Y-%m-%d %H:%M:%S')"

# RUY-1014: .play art is WebP (05); Qt decodes it only with qt6-qtimageformats. The plugin file is there
# and the shell's journal since boot has no "Unsupported image format" (WEBP_PLUGIN: a host fixture's path).
webp_checks() {
    local plugin="${WEBP_PLUGIN:-/usr/lib64/qt6/plugins/imageformats/libqwebp.so}" bad_img
    [ -f "$plugin" ] && ok "the Qt WebP image plugin is installed" || bad "the Qt WebP image plugin is missing: $plugin"
    bad_img="$(journalctl -b -o cat 2>/dev/null | grep -a 'Unsupported image format' | head -3)"
    [ -z "$bad_img" ] && ok "no Unsupported image format in the journal since boot"         || bad "the shell could not decode an image: $bad_img"
}

# ADR-036: no SELinux denial of PID 1 (init_t) while the check ran. A denied OpenFile= of the
# source shows up only as "missing" (graceful), so the journal is the proof.
module_check() { # <name>: the SELinux module is loaded
    [ -n "$(semodule -l 2>/dev/null | grep -x "$1")" ] && ok "the SELinux module $1 is loaded" || bad "the SELinux module $1 is not loaded"
}
avc_checks() {
    module_check ruya_play_openfile
    local denied
    denied="$(journalctl --since "$since" -o cat 2>/dev/null | grep 'avc:  denied' | grep 'scontext=system_u:system_r:init_t')"
    [ -z "$denied" ] && ok "no init_t AVC denial during the check" \
        || bad "init_t AVC denials during the check: $(echo "$denied" | head -3)"
}
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# --- JSON (busctl --json=short), by key ---------------------------------------------------------
parse() { # <what> [arg]
    python3 -c '
import json, sys
what = sys.argv[1]
arg = sys.argv[2] if len(sys.argv) > 2 else ""
doc = json.load(sys.stdin)
data = doc.get("data", [])
def val(v):
    return v.get("data") if isinstance(v, dict) and "type" in v and "data" in v else v
if what == "status":
    print(data[0] if data else "")
elif what == "second":
    print(data[1] if len(data) > 1 else "")
elif what == "job":
    for j in (data[0] if data else []):
        if val(j.get("id")) == arg:
            print(val(j.get("state")), val(j.get("status")))
            break
elif what == "sources":
    for s in (data[0] if data else []):
        print(val(s.get("path")))
elif what == "items":
    for s in (data[0] if data else []):
        print(val(s.get("id")))
elif what == "keys":
    # A Store1 GetPermissions answer (sasasas): the list named by arg
    i = {"effective": 1, "withdrawn": 2, "withdrawable": 3}.get(arg, 0)
    print(" ".join(data[i]) if i and len(data) > i else "")
elif what == "key":
    rec = data[1] if len(data) > 1 else {}
    print(val(rec.get(arg)) if arg in rec else "")
elif what == "artpaths":
    # the vetted art of an Inspect record: every role path, then the screenshot paths (RUY-1038)
    rec = data[1] if len(data) > 1 else {}
    for p in (val(rec.get("art")) or {}).values():
        print(p)
    for p in (val(rec.get("screenshots")) or []):
        print(p)
elif what == "codes":
    rec = data[1] if len(data) > 1 else {}
    for p in (val(rec.get("problems")) or []):
        print(p[0])
elif what == "resolution":
    # A Library1 ResolveRunner answer (sa{sv}): "<source>/<family>/<version>" as the launcher status file
    # names a runner, then " fallback" when the choice asked for could not be honoured (RUY-905);
    # "refused <code>" when the launch would refuse; "<status>" alone when the status is not ok
    rec = data[1] if len(data) > 1 else {}
    if data and data[0] != "ok":
        print(data[0])
    elif "play_runner" in rec:
        family, _, version = val(rec["play_runner"]).partition(" ")
        print("%s/%s/%s%s" % (val(rec.get("play_runner_source")), family, version, " fallback" if val(rec.get("play_fallback")) else ""))
    elif "play_resolve_code" in rec:
        print("refused " + val(rec["play_resolve_code"]))
    else:
        print("no runner")
' "$@"
}

# Flatpak permission sections (flatpak info --show-permissions) as sorted "[Section] key=value"
# lines, one per list entry, so order and trailing semicolons do not matter.
perm_lines() {
    python3 -c '
import sys
section, out = None, set()
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("[") and line.endswith("]"):
        section = line[1:-1]
        continue
    if section is None or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if section == "Context":
        for v in value.split(";"):
            if v:
                out.add("[%s] %s=%s" % (section, key, v))
    else:
        out.add("[%s] %s=%s" % (section, key, value))
for x in sorted(out):
    print(x)
'
}

# What 05 section 8 maps the perms package to: the native runner's base set plus network,
# multiarch and gamemode.
PERMS_WANT='[Context] devices=dri
[Context] features=multiarch
[Context] shared=ipc
[Context] shared=network
[Context] sockets=pulseaudio
[Context] sockets=wayland
[Session Bus Policy] com.feralinteractive.GameMode=talk'

# What the sandbox of an app can do, one fact per line (RUY-854): whether it connects to the TCP
# port in $1 on 127.0.0.1 (the host's loopback is reachable only with the network shared; a sandbox
# whose network was withdrawn has its own) and how many interfaces other than lo it sees.
# $PROC_NET_DEV points the host fixtures at a made-up table.
NET_PROBE='n=0
while read -r line; do
    case "$line" in
        *:*) name="${line%%:*}"; name="${name// /}"; [ "$name" != lo ] && n=$((n + 1)) ;;
    esac
done < "${PROC_NET_DEV:-/proc/net/dev}"
echo "net=$n"
if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then echo "connect=yes"; else echo "connect=no"; fi'

# patch_manifest <in.zip> <out.zip> <json>: a copy of a package whose top-level play.json has the JSON
# merge patch applied (an object merges key by key, anything else replaces; RFC 7386 without null).
# The sample is unsigned and play.files does not list play.json, so nothing else names what changes; a
# signed package would need signing again.
patch_manifest() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys, zipfile
src, out, patch = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
def merge(doc, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(doc.get(key), dict):
            merge(doc[key], value)
        else:
            doc[key] = value
sample = zipfile.ZipFile(src)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for i in sample.infolist():
        b = sample.read(i.filename)
        if i.filename.endswith("play.json") and i.filename.count("/") <= 1:
            m = json.loads(b)
            merge(m, patch)
            b = json.dumps(m, indent=2).encode()
        z.writestr(i, b)
PY
}

# with_id <in.zip> <out.zip> <id>: a copy of a package with <id> as its id (RUY-877).
with_id() {
    patch_manifest "$1" "$2" "$(python3 -c 'import json, sys; print(json.dumps({"id": sys.argv[1]}))' "$3")"
}

# windows_pkg <in.zip> <out.zip> <id>: what launch-windows installs: the Windows sample under <id>
# with check.exe, its 32-bit console program in its writable folder Program/ (RUY-1019), as the
# command, and the one permission 32-bit code needs (RUY-902; the headless VM cannot play hello.exe,
# which waits for the arrow keys).
windows_pkg() {
    patch_manifest "$1" "$2" "$(python3 -c '
import json, sys
print(json.dumps({"id": sys.argv[1], "run": {"command": ["${game}/Program/check.exe"]}, "permissions": {"multiarch": True}}))
' "$3")"
}

# bundled_version <runners dir>: the version of the bundled copy bundled_pkg makes (RUY-1248): the OS's
# newest proton-ge with its last number raised by one, so the bundled copy is the higher of the two
# (05 section 6.2: `newest` takes the higher version, a tie goes to the bundled copy; the rise keeps the
# check from passing on a tie). GE-Proton11-13 gives GE-Proton11-14.
bundled_version() {
    local dir
    dir="$(system_runner_dir "$1")" || return 1
    python3 -I - "$1/$dir/runner.json" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    version = json.load(f)["version"]
raised = re.sub(r"(\d+)(\D*)$", lambda m: str(int(m.group(1)) + 1) + m.group(2), version)
if raised == version or len(raised) > 32:
    sys.exit("bundled_version: no version above %s" % version)
print(raised)
PY
}

# bundled_pkg <in.zip> <out.zip> <id> <source> <bump> <runners dir>: what the bundled mode installs (RUY-1248):
# the Windows sample as launch-windows installs it (windows_pkg), its component given `source: <source>` and a
# bundled copy under components/proton of the OS's family and kind with the version bundled_version gives,
# its build raised by <bump>. The copy is two files, listed in play.files: runner.json, and `proton` (with the
# licence text a bundled component needs, licences/proton-CC0-1.0.txt, ruya-pack validate wants it), a
# script that appends "<version> <first argument>" to <data>/bundled-runner-ran and runs the image's GE-Proton
# (/app/runners/<its folder>/proton) with the same arguments. So the launcher starts the bundled entry as it
# starts any bundled runner and the game runs on a real Proton, while the package holds none of GE-Proton's
# 1.5 GiB (nothing of it is redistributed). Whether the bundled or the system runner ran is the status file's
# runner= and the marker file.
bundled_pkg() {
    local dir ver
    dir="$(system_runner_dir "$6")" || return 1
    ver="$(bundled_version "$6")" || return 1
    windows_pkg "$1" "$2.win" "$3" || return 1
    python3 -I - "$2.win" "$2" "$4" "$5" "$ver" "$dir" "$6/$dir/runner.json" <<'PY'
import hashlib, json, sys, zipfile
src, out, source, bump, version, runner_dir, system_json = sys.argv[1:8]
with open(system_json, encoding="utf-8") as f:
    system = json.load(f)
runner = {"format": 1, "family": system["family"], "kind": system["kind"], "version": version, "arch": "x86_64",
          "entry": {"proton": "proton"}, "licence": "CC0-1.0"}
script = """#!/bin/sh
# The bundled runner of vm-play-check.sh bundled (RUY-1248): records that the launcher started it, then
# is the image's GE-Proton. It holds none of GE-Proton's files.
echo "@VERSION@ $1" >> "${XDG_DATA_HOME:?}/bundled-runner-ran"
exec /app/runners/@DIR@/proton "$@"
""".replace("@VERSION@", version).replace("@DIR@", runner_dir)
# A bundled component needs its licence text under licences/ (05 section 6.2; ruya-pack validate: licence.text_missing).
licence = "The two files in components/proton are dedicated to the public domain (CC0-1.0).\n"
new = {
    "components/proton/proton": (script.encode(), 1),
    "components/proton/runner.json": ((json.dumps(runner, indent=2) + "\n").encode(), 0),
    "licences/proton-CC0-1.0.txt": (licence.encode(), 0),
}
z = zipfile.ZipFile(src)
roots = [n[: -len("play.json")] for n in z.namelist() if n.endswith("play.json") and n.count("/") <= 1]
if len(roots) != 1:
    sys.exit("bundled_pkg: %s has no single play.json" % src)
root = roots[0]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as o:
    for i in z.infolist():
        b, name = z.read(i.filename), i.filename[len(root):]
        if name in new:
            sys.exit("bundled_pkg: %s already has %s" % (src, name))
        if name == "play.json":
            m = json.loads(b)
            m["build"] += int(bump)
            c = next(c for c in m["components"] if c["id"] == m["run"]["component"])
            c["source"] = source
            c.setdefault("min", system["version"])
            c["bundled"] = {"path": "components/proton", "version": version, "licence": "CC0-1.0"}
            b = json.dumps(m, indent=2).encode()
        elif name == "play.files":
            lines = [json.loads(l) for l in b.decode("utf-8").splitlines()]
            for path, (data, x) in new.items():
                e = {"p": path, "t": "f", "s": len(data), "h": hashlib.sha256(data).hexdigest()}
                if x:
                    e["x"] = 1
                lines.append(e)
            lines.sort(key=lambda e: e["p"].encode("utf-8"))
            b = ("\n".join(json.dumps(e, separators=(",", ":"), ensure_ascii=False) for e in lines) + "\n").encode("utf-8")
        o.writestr(i, b)
    for path, (data, x) in new.items():
        o.writestr(root + path, data)
PY
    local rc=$?
    rm -f "$2.win"
    return "$rc"
}

# bump_build <in.zip> <out.zip> <path> <text>: the next build of a package (play.json build+1) whose
# file payload/<path> holds <text>, its play.files line given the new size and SHA-256 (the package
# stays unsigned, as launch-windows installs it); prints the new build. What launch-windows installs as
# the update (RUY-1019).
bump_build() {
    python3 -I - "$@" <<'PY'
import hashlib, json, sys, zipfile
src, out, rel, text = sys.argv[1:5]
path, data = "payload/" + rel, text.encode()
z = zipfile.ZipFile(src)
roots = [n[: -len("play.json")] for n in z.namelist() if n.endswith("play.json") and n.count("/") <= 1]
if len(roots) != 1 or (roots[0] + path) not in z.namelist():
    sys.exit("bump_build: %s has no single play.json or no %s" % (src, path))
root, build = roots[0], None
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as o:
    for i in z.infolist():
        b, name = z.read(i.filename), i.filename[len(root):]
        if name == "play.json":
            m = json.loads(b)
            m["build"] = build = m["build"] + 1
            b = json.dumps(m, indent=2).encode()
        elif name == "play.files":
            lines = []
            for line in b.decode("utf-8").splitlines():
                e = json.loads(line)
                if e.get("p") == path:
                    e["s"], e["h"] = len(data), hashlib.sha256(data).hexdigest()
                lines.append(json.dumps(e, separators=(",", ":"), ensure_ascii=False))
            b = ("\n".join(lines) + "\n").encode("utf-8")
        elif name == path:
            b = data
        o.writestr(i, b)
print(build)
PY
}

# module_path <check.txt>: the module= line of check.exe's report (GetModuleFileNameW's path, RUY-1019)
# as the Unix path Wine maps it to: Z: is / (dosdevices/z:), so Z:\a\b is /a/b. Prints nothing and
# returns 1 for another drive, no such line or no file.
module_path() {
    python3 -I - "$1" <<'PY'
import sys
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    sys.exit(1)
m = next((l[len("module="):].strip() for l in lines if l.startswith("module=")), "")
if len(m) < 3 or m[0] not in "zZ" or m[1:3] != ":\\":
    sys.exit(1)
print(m[2:].replace("\\", "/"))
PY
}

# asks_network <in.zip> <out.zip>: a copy of a package whose play.json asks for network, multiarch
# and gamemode (perms: the 05 section 8 mapping; remove: an app with a permission to withdraw).
asks_network() {
    patch_manifest "$1" "$2" '{"permissions": {"network": true, "multiarch": true, "gamemode": true}}'
}

# The format's longest id (MAX_ID_BYTES in services/ruya-play-format/src/limits.rs; the host fixtures
# check the two agree). ruya-play refuses a longer id, so pkg_id must not make one.
PLAY_MAX_ID_BYTES=120

# pkg_id <id> <part>: the package id a mode installs under, "<id>_<part>": the part is joined to the
# last id part with "_", so the id stays valid whatever that part holds (a "-" is allowed in the last
# part only, so a new dotted part after it would break the id). The one id-suffix rule: every mode
# (check, verify, perms) and vm-library-check.sh (`pkgid` mode) go through it. Prints nothing and
# returns 1 when the result would pass PLAY_MAX_ID_BYTES.
pkg_id() {
    local r="$1_$2"
    [ "${#r}" -le "$PLAY_MAX_ID_BYTES" ] || { echo "FAIL: the package id '$r' is longer than $PLAY_MAX_ID_BYTES bytes; the sample's id is too long for this check" >&2; return 1; }
    echo "$r"
}

# run_id <id>: check's package id for this run: the part "c<time>x<pid>" starts with a letter (a part
# may not start with a digit, ruya-play-format check_id) and the pid keeps two runs in one second apart.
run_id() { pkg_id "$1" "c$(date +%s)x$$"; }

# generation <installed.json> <id> [<n>]: the metadata generation recorded for <id> (RUY-900; an
# entry without one reads 0, no entry prints "none"), after setting it to <n> when given.
generation() {
    python3 - "$@" <<'PY'
import json, sys
path, ident = sys.argv[1], sys.argv[2].lower()
with open(path) as f:
    doc = json.load(f)
entry = next((e for e in doc["installed"] if e["id"].lower() == ident), None)
if entry is None:
    print("none")
    sys.exit(0)
if len(sys.argv) > 3:
    entry["generation"] = int(sys.argv[3])
    with open(path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
print(entry.get("generation", 0))
PY
}

# ADR-038 (RUY-900): an app recorded with an older metadata generation is committed again at the
# next start, once. The service is stopped while installed.json is edited (it keeps the file in
# memory), and the second start must plan nothing for the app.
recommit_check() { # <id>
    local id="$1" before t n
    before="$(flatpak info --system --show-commit "play.$id" 2>/dev/null)"
    systemctl stop ruya-play.service
    generation "$state/state/installed.json" "$id" 0 >/dev/null
    t="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl start ruya-play.service || { bad "ruya-play.service did not start for the recommit"; return; }
    n=0
    while [ "$n" -lt 120 ]; do
        journalctl -u ruya-play.service --since "$t" -o cat | grep -qx "ruya-play: recommitted play.$id" && break
        sleep 1; n=$((n + 1))
    done
    journalctl -u ruya-play.service --since "$t" -o cat | grep -qx "ruya-play: recommitted play.$id" \
        && ok "play.$id of generation 0 is committed again at start" \
        || bad "play.$id of generation 0 was not committed again: $(journalctl -u ruya-play.service --since "$t" -o cat | grep "play.$id" | tail -3)"
    [ "$(generation "$state/state/installed.json" "$id")" -ge 1 ] 2>/dev/null \
        && ok "its generation is stamped again" \
        || bad "installed.json has generation $(generation "$state/state/installed.json" "$id") for $id"
    [ "$(flatpak info --system --show-commit "play.$id" 2>/dev/null)" != "$before" ] \
        && ok "a new commit of play.$id is installed" || bad "play.$id still has commit $before"
    flatpak info --system --show-metadata "play.$id" 2>/dev/null | grep -qx '\[Extension org.ruyaos.Play.Runner\]' \
        && ok "the new metadata declares the runners' point" || bad "the new metadata has no org.ruyaos.Play.Runner point"
    t="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl restart ruya-play.service
    n=0
    while [ "$n" -lt 30 ]; do
        journalctl -u ruya-play.service --since "$t" -o cat | grep -q '^ruya-play: serving' && break
        sleep 1; n=$((n + 1))
    done
    journalctl -u ruya-play.service --since "$t" -o cat | grep -q "Recommit { id: \"$id\" }" \
        && bad "play.$id is planned for a recommit again on an unchanged generation" \
        || ok "a second start plans no recommit for play.$id"
}

# --- launching the installed samples as a profile (RUY-902) -----------------------------------------

# signals <monitor.log> <member> <app id>: one line per Session1 signal <member> of the app in a
# `busctl --json=short monitor` log: the instance, then the arguments after the app id (AppStarted:
# "inst"; AppExited: "inst 0 quit", the exit code and the reason). Other lines are skipped.
signals() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
log, member, app = sys.argv[1:4]
for line in open(log, encoding="utf-8", errors="replace"):
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("member") != member:
        continue
    data = (msg.get("payload") or {}).get("data") or []
    if len(data) > 1 and data[1] == app:
        print(" ".join(str(x) for x in [data[0]] + data[2:]))
PY
}

# launcher_state <state.json>: the launcher's status file (05 section 6.3, step 7) as
# "epoch=<n> setup_done=<ids> runner=<source>/<family>/<version>" ("runner=none" for a native game),
# then " game=<n>" when it records the build of a game tree (game_build, RUY-1019).
launcher_state() {
    python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        state = json.load(f)
except (OSError, ValueError) as e:
    print("unreadable: %s" % e)
    sys.exit(0)
r = state.get("runner")
runner = "none" if r is None else "%s/%s/%s" % (r.get("source"), r.get("family"), r.get("version"))
game = "" if state.get("game_build") is None else " game=%s" % state.get("game_build")
print("epoch=%s setup_done=%s runner=%s%s" % (state.get("epoch"), ",".join(state.get("setup_done", [])), runner, game))
PY
}

# compat_i386 <app>: prints the Compat.i386 ref of the app's runtime (the 32-bit loader, /lib/ld-linux.so.2, a 32-bit
# Windows program needs inside the sandbox, RUY-999); fails when that ref is not installed. It asks flatpak about the
# refs instead of starting the sandbox, which needs the profile's session and a display.
compat_i386() {
    local rt
    rt="$(flatpak info --system --show-runtime "$1" 2>/dev/null)" || return 1
    echo "${rt%%/*}.Compat.i386/${rt#*/}"
    flatpak info --system "${rt%%/*}.Compat.i386/${rt#*/}" >/dev/null 2>&1
}

# system_runner_dir <runners dir>: the folder name of the newest proton-ge runner below <dir>. Which
# folder is the newest is vm-runner-check.sh's `newest` mode (one copy of the version rule).
system_runner_dir() {
    local rc
    rc="$(dirname "$0")/vm-runner-check.sh"
    [ -f "$rc" ] || { echo "no $rc: copy vm-runner-check.sh next to this script" >&2; return 1; }
    bash "$rc" newest "$1" family=proton-ge
}

# system_runner <runners dir>: "<family>/<version>" of the newest proton-ge runner.json one folder below
# <dir> (the OS's GE-Proton: what the status file names after a system-runner launch); its runner.json
# says the rest.
system_runner() {
    local dir
    dir="$(system_runner_dir "$1")" || return 1
    python3 -I - "$1/$dir/runner.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    r = json.load(f)
print("%s/%s" % (r["family"], r["version"]))
PY
}

# RUY-1039: the libraries a Windows game's runtime must still load with GE-Proton's own library folder
# first in LD_LIBRARY_PATH (the `proton` script puts files/lib/x86_64-linux-gnu first). A runner library
# that shadows a runtime one it is older than breaks the dlopen that needs the newer one: GE-Proton's
# libxkbcommon 0.9.2 broke libSDL3, sdl2-compat aborted winebus and no game saw a controller.
RUNNER_LIBS="libSDL2-2.0.so.0 libSDL3.so.0 libudev.so.1 libvulkan.so.1 libfreetype.so.6 libgnutls.so.30 libpulse.so.0"
# LIB_PROBE <runner root> <soname>...: run inside the sandbox; one line "ok <soname>" or "FAIL <soname>:
# <last line of the error>" each. Every load is a child process: a library that aborts the process is a
# FAIL line, not the end of the check.
LIB_PROBE='root="$1"; shift
export LD_LIBRARY_PATH="$root/files/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
for lib in "$@"; do
    if err="$(python3 -I -c "import ctypes, sys; ctypes.CDLL(sys.argv[1])" "$lib" 2>&1)"; then
        echo "ok $lib"
    else
        echo "FAIL $lib: $(echo "$err" | tail -n 1)"
    fi
done'

# runner_lib_checks <app id> <runner folder>: RUNNER_LIBS load in the app's sandbox with the runner's
# library folder first.
runner_lib_checks() {
    local line out
    echo "--- RUY-1039: the runtime's libraries load with the runner's library folder first"
    out="$(flatpak run --system --command=bash "$1" -c "$LIB_PROBE" probe "/app/runners/$2" $RUNNER_LIBS 2>&1)"
    for lib in $RUNNER_LIBS; do
        line="$(echo "$out" | grep -m1 -F " $lib")"
        case "$line" in
            "ok $lib") ok "$lib loads with $2's libraries first" ;;
            *) bad "$lib with $2's libraries first: ${line:-no answer: $out}" ;;
        esac
    done
}

# pad_event_fd <winebus winedevice pid>... : prints "<pid> <node>" of the first of these processes that
# holds an event node of a virtual pad (its phys is ruya-input/pad<n>); status 1 when none does.
pad_event_fd() {
    local pid fd node
    for pid in "$@"; do
        for fd in "/proc/$pid/fd/"*; do
            node="$(readlink "$fd" 2>/dev/null)"
            case "$node" in
                /dev/input/event*)
                    case "$(cat "/sys/class/input/${node##*/}/device/phys" 2>/dev/null)" in
                        ruya-input/pad*) echo "$pid $node"; return 0 ;;
                    esac ;;
            esac
        done
    done
    return 1
}

# winebus_pids: the processes that have Wine's winebus mapped (the winedevice that hosts it).
winebus_pids() {
    local m
    for m in /proc/[0-9]*/maps; do
        grep -q 'winebus' "$m" 2>/dev/null && { m="${m#/proc/}"; echo "${m%/maps}"; }
    done
}

# watch_winebus <result file> <seconds>: in the background, until a winebus process holds a virtual pad's
# event node: writes "<pid> <node>" to the file. The winedevice lives only while the game does, so the
# check polls through the first launch instead of looking once after it.
watch_winebus() {
    local out="$1" i=0 got
    : > "$out"
    while [ "$i" -lt "$2" ]; do
        # shellcheck disable=SC2046 # the pids are numbers
        got="$(pad_event_fd $(winebus_pids))" && { echo "$got" > "$out"; return 0; }
        sleep 1; i=$((i + 1))
    done
}


# offline <on|off> <dir>: on takes the default routes away (IPv4 and IPv6) and keeps them in <dir>; off puts
# them back. The guest stays reachable on its own subnet, so the ssh session lives. Prints nothing. Both
# directions go through every route of both families, note a failure and return 1 at the end (a half-done
# `on` is undone by `off`, whatever failed; the caller sets its "routes are away" flag before `on`). `off`
# restores with `ip route replace`, so a route that is back already is no error, and removes a family's
# saved file only when all its routes are back.
offline() {
    local act="$1" dir="$2" fam r failed=0 left
    for fam in -4 -6; do
        if [ "$act" = on ]; then
            ip "$fam" route show default >> "$dir/routes$fam"
            while [ -n "$(ip "$fam" route show default)" ]; do
                ip "$fam" route del default || { failed=1; break; }
            done
        else
            [ -f "$dir/routes$fam" ] || continue
            left=0
            while read -r r; do
                [ -n "$r" ] || continue
                ip "$fam" route replace $r || { left=1; failed=1; }
            done < "$dir/routes$fam"
            [ "$left" = 0 ] && rm -f "$dir/routes$fam"
        fi
    done
    return "$failed"
}

if [ "$mode" = parse ]; then
    if [ "${2:-}" = perms ]; then
        perm_lines
        exit $?
    fi
    parse "${2:-}" "${3:-}"
    exit $?
fi
if [ "$mode" = asknet ]; then
    asks_network "${2:?in.zip}" "${3:?out.zip}"
    exit $?
fi
if [ "$mode" = withid ]; then
    with_id "${2:?in.zip}" "${3:?out.zip}" "${4:?id}"
    exit $?
fi
if [ "$mode" = pkgid ]; then
    pkg_id "${2:?id}" "${3:?part}"
    exit $?
fi
if [ "$mode" = runid ]; then
    run_id "${2:?id}"
    exit $?
fi
if [ "$mode" = generation ]; then
    generation "${2:?installed.json}" "${3:?id}" ${4:+"$4"}
    exit $?
fi
if [ "$mode" = signals ]; then
    signals "${2:?monitor.log}" "${3:?member}" "${4:?app id}"
    exit $?
fi
if [ "$mode" = winpkg ]; then
    windows_pkg "${2:?in.zip}" "${3:?out.zip}" "${4:?id}"
    exit $?
fi
if [ "$mode" = lstate ]; then
    launcher_state "${2:?state.json}"
    exit $?
fi
if [ "$mode" = bumpbuild ]; then
    bump_build "${2:?in.zip}" "${3:?out.zip}" "${4:?path}" "${5:?text}"
    exit $?
fi
if [ "$mode" = modpath ]; then
    module_path "${2:?check.txt}"
    exit $?
fi
if [ "$mode" = sysrunner ]; then
    system_runner "${2:?runners dir}"
    exit $?
fi
if [ "$mode" = bundledver ]; then
    bundled_version "${2:?runners dir}"
    exit $?
fi
if [ "$mode" = bundledpkg ]; then
    bundled_pkg "${2:?in.zip}" "${3:?out.zip}" "${4:?id}" "${5:?source}" "${6:?bump}" "${7:?runners dir}"
    exit $?
fi
if [ "$mode" = libprobe ]; then
    # shellcheck disable=SC2086 # the sonames are a word list
    bash -c "$LIB_PROBE" probe "${2:?runner root}" ${3:?sonames}
    exit $?
fi
if [ "$mode" = compat32 ]; then
    compat_i386 "${2:?app id}"
    exit $?
fi
if [ "$mode" = offline ]; then
    offline "${2:?on|off}" "${3:?dir}"
    exit $?
fi

[ "$(id -u)" = 0 ] || { echo "FAIL: run as root"; exit 1; }
as_shell() { runuser -u ruya-shell -- "$@"; }
call() { as_shell busctl --system --json=short call "$svc" "$obj" "$svc" "$@"; }

id_of() { # the package id from play.json in the zip
    python3 - "$1" <<'PY'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
name = next(n for n in z.namelist() if n.endswith("play.json") and n.count("/") <= 1)
print(json.loads(z.read(name))["id"])
PY
}

leftovers() { # the service's staging/ exists and is empty after a finished job
    [ -d "$staging" ] || return 1
    n="$(find "$staging" -mindepth 1 2>/dev/null | wc -l)"
    [ "$n" = 0 ] || return 1
    return 0
}

# Inspect <path> is ok, its record's verdict is <verdict>, and it lists no internal fault
# (staging.*, helper.*): on 0.0.93 the method said ok while the record held staging.io (RUY-866).
# Rule problems (an unsigned package's tier, a broken optional art slot) are not faults here.
# An empty <verdict> accepts any. Prints "ok" or what was wrong.
inspect_clean() {
    out="$(call Inspect s "$1")" || { echo "call-failed"; return; }
    st="$(echo "$out" | parse status)"
    [ "$st" = ok ] || { echo "$st"; return; }
    verdict="$(echo "$out" | parse key verdict)"
    faults="$(echo "$out" | parse codes | grep -E '^(staging|helper)\.' | tr '\n' ' ')"
    if [ -n "$faults" ]; then echo "ok with faults: $faults"
    elif [ -n "${2:-}" ] && [ "$verdict" != "$2" ]; then echo "verdict $verdict, want $2"
    else echo ok; fi
}

# Install <path> and wait for the job to finish; prints the JobFinished status.
install_wait() {
    out="$(call Install 'sa{sv}' "$1" 1 admin_approved b true)" || { echo "call-failed"; return; }
    st="$(echo "$out" | parse status)"
    [ "$st" = ok ] || { echo "method-$st"; return; }
    job="$(echo "$out" | parse second)"
    n=0
    while [ "$n" -lt 300 ]; do
        line="$(call ListJobs | parse job "$job")"
        case "$line" in finished\ *) echo "${line#finished }"; return ;; esac
        sleep 1; n=$((n + 1))
    done
    echo "timeout"
}

dev_mode() { call SetDeveloperMode 'ba{sv}' "$1" 1 admin_approved b true | parse status; }

pid_of() { systemctl show -p MainPID --value ruya-play.service; }

# --- the helper's sandbox ------------------------------------------------------------------------
helper_checks() {
    echo "== systemd-analyze security =="
    systemd-analyze security ruya-play.service | tail -1
    mapfile -t argv < <(/usr/bin/ruya-play --helper-argv "$1")
    [ "${#argv[@]}" -gt 3 ] || { bad "ruya-play --helper-argv printed no command line"; return; }
    # The helper's own properties around a probe instead of the helper.
    # In /run, not /tmp: PID 1 (init_t) opens it for the probe unit and may not write the ssh
    # session's user_tmp_t files (a check artefact, lead-34).
    pout="$(mktemp -p /run)"
    probe=()
    skip=0
    for a in "${argv[@]}"; do
        [ "$a" = "--" ] && break
        if [ "$skip" = 1 ]; then
            skip=0
            case "$a" in
                Standard*=*) unset 'probe[-1]' ;;  # the helper's request and output files are not the probe's
                *) probe+=("$a") ;;
            esac
            continue
        fi
        [ "$a" = "-p" ] && skip=1
        case "$a" in --unit=*) probe+=("--unit=ruya-play-helper-probe") ;; *) probe+=("$a") ;; esac
    done
    # RUY-839: never --pipe (PID 1 may not use our descriptors): the manager opens the output file.
    probe+=(-p "StandardOutput=file:$pout" -p "StandardError=inherit")
    "${probe[@]}" -- /bin/bash -c '
        if (exec 4<>/dev/tcp/1.1.1.1/80) 2>/dev/null; then echo NET-OPEN; else echo NET-CLOSED; fi
        if touch /var/lib/ruya-play/x 2>/dev/null || touch /etc/x 2>/dev/null; then echo WRITE-OUTSIDE; else echo WRITE-CONFINED; fi
        if touch /var/lib/ruya-play-helper-probe/x 2>/dev/null; then echo WRITE-STATE; fi
        if [ -n "${LISTEN_FDS:-}" ] && head -c 4 <&3 >/dev/null 2>&1; then echo READ-FD; else echo NO-FD; fi
        sleep 3' < /dev/null > /dev/null 2>&1 &
    probe_pid=$!
    sleep 1
    echo "probe unit: $(systemd-analyze security ruya-play-helper-probe.service 2>/dev/null | tail -1)"
    wait "$probe_pid"
    out="$(cat "$pout")"; rm -f "$pout"
    case "$out" in *NET-OPEN*) bad "the helper's sandbox reaches the network" ;; *NET-CLOSED*) ok "the helper's sandbox has no network" ;; *) bad "the network probe did not run: $out" ;; esac
    case "$out" in *WRITE-OUTSIDE*) bad "the helper's sandbox writes outside its state folder" ;; *WRITE-CONFINED*) ok "the helper's sandbox cannot write outside its state folder" ;; esac
    case "$out" in *WRITE-STATE*) ok "the helper's sandbox writes its StateDirectory" ;; *) bad "the helper's sandbox cannot write its StateDirectory" ;; esac
    case "$out" in *READ-FD*) ok "the helper reads the passed descriptor of $1" ;; *) bad "the helper got no readable descriptor for $1" ;; esac
    rm -rf /var/lib/private/ruya-play-helper-probe
    rm -f /var/lib/ruya-play-helper-probe
}

# Wait for the job a Verify or Remove call named (its busctl output is $1, or empty when the call
# failed); prints "<method status> <job status or ->" and, once accepted, the job.
job_wait() {
    [ -n "$1" ] || { echo "call-failed -"; return; }
    st="$(echo "$1" | parse status)"
    [ "$st" = ok ] || { echo "$st -"; return; }
    job="$(echo "$1" | parse second)"
    n=0
    while [ "$n" -lt 300 ]; do
        line="$(call ListJobs | parse job "$job")"
        case "$line" in finished\ *) echo "ok ${line#finished } $job"; return ;; esac
        sleep 1; n=$((n + 1))
    done
    echo "ok timeout $job"
}

# Verify <id> and wait for the job (RUY-834).
verify_wait() { job_wait "$(call Verify s "$1")"; }

verify_checks() {
    app="/var/lib/flatpak/app/play.$appid/current/active/files"
    [ -d "$app" ] || { bad "no deployment at $app"; return; }
    set -- $(verify_wait "play.$appid")
    [ "$1 $2" = "ok ok" ] && ok "Verify of the installed sample finishes ok" || bad "Verify of the installed sample: $*"
    # One listed file, from the stored play.files.
    victim="$(python3 - "$app/play.files" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(line)
    if e["t"] == "f" and e["s"] > 0:
        print(e["p"])
        break
PY
)"
    [ -n "$victim" ] && [ -f "$app/$victim" ] || { bad "no listed file to damage in $app/play.files"; return; }
    size="$(stat -c %s "$app/$victim")"
    printf x >> "$app/$victim"
    set -- $(verify_wait "play.$appid")
    [ "$1 $2" = "ok invalid-package" ] && ok "a changed file makes Verify finish invalid-package" || bad "Verify after damaging $victim: $*"
    grep -q 'package.hash_mismatch' "$state/state/jobs" && ok "the job table records package.hash_mismatch" || bad "state/jobs has no package.hash_mismatch"
    truncate -s "$size" "$app/$victim"
    : > "$app/zz-extra-file"
    set -- $(verify_wait "play.$appid")
    [ "$1 $2" = "ok invalid-package" ] && ok "an extra file makes Verify finish invalid-package" || bad "Verify with an extra file: $*"
    rm -f "$app/zz-extra-file"
    set -- $(verify_wait "play.$appid")
    [ "$1 $2" = "ok ok" ] && ok "Verify is ok again once the damage is undone" || bad "Verify after the repair: $*"
    set -- $(verify_wait "play.com.example.not-installed")
    [ "$1" = unknown-app ] && ok "Verify of an app that is not installed is unknown-app" || bad "Verify of an unknown app: $*"
    set -- $(verify_wait "")
    [ "$1" = invalid ] && ok "Verify of an empty id is invalid" || bad "Verify of an empty id: $*"
}

store_call() { busctl --system --json=short call org.ruyaos.Store1 /org/ruyaos/Store1 org.ruyaos.Store1 "$@" 2>&1; }
# The app's override on one line (for a failure message).
override_text() { flatpak override --system --show "$1" 2>&1 | tr '\n' ' '; }

# Remove <app id> as an admin and wait for the job (RUY-816).
remove_wait() { job_wait "$(call Remove 'sa{sv}' "$1" 1 admin_approved b true)"; }

# remove_app <flatpak app id> (RUY-1001): the one way a check removes a .play app, the `removeapp` mode:
# through Play1.Remove and the job's end, so ruya-play forgets the build too. An app that is not
# installed is nothing to remove.
remove_app() {
    local st job
    read -r st job _ <<< "$(remove_wait "$1")"
    case "$st $job" in
        "ok ok" | "unknown-app -") return 0 ;;
    esac
    bad "Play1.Remove of $1: $st $job"
    return 1
}

remove_checks() {
    app="/var/lib/flatpak/app/play.$appid"
    [ -d "$app" ] || { bad "no deployment at $app"; return; }
    grep -q "\"$appid\"" "$state/state/installed.json" && ok "the install recorded the build" || bad "state/installed.json has no entry for $appid"
    # The refusals first: nothing may be removed by them.
    set -- $(call Remove 'sa{sv}' "play.$appid" 0 | parse status)
    [ "$1" = forbidden ] && ok "Remove without admin_approved is forbidden" || bad "Remove without admin_approved: $*"
    set -- $(call Remove 'sa{sv}' "" 1 admin_approved b true | parse status)
    [ "$1" = invalid ] && ok "Remove of an empty id is invalid" || bad "Remove of an empty id: $*"
    set -- $(remove_wait "org.example.NotPlay")
    [ "$1" = unknown-app ] && ok "Remove of an app that is not play.<id> is unknown-app" || bad "Remove of a non-play app: $*"
    set -- $(remove_wait "play.com.example.not-installed")
    [ "$1" = unknown-app ] && ok "Remove of an app that is not installed is unknown-app" || bad "Remove of an unknown app: $*"
    [ -d "$app" ] && ok "the refusals removed nothing" || bad "a refused Remove removed $app"
    # RUY-923: an admin withdrew the network, so the app has an override that the removal must drop.
    [ "$(store_call WithdrawPermission ss "play.$appid" network | parse status)" = ok ] && ok "WithdrawPermission network by root" || bad "WithdrawPermission network"
    flatpak override --system --show "play.$appid" | grep -q '^shared=!network;' && ok "the app has an override (shared=!network)" || bad "no override to remove: $(override_text "play.$appid")"
    # The removal.
    set -- $(remove_wait "play.$appid")
    [ "$1 $2" = "ok ok" ] && ok "Remove of the installed sample finishes ok" || bad "Remove of the installed sample: $*"
    [ ! -e "$app" ] && ok "the deployment is gone" || bad "$app is still there after Remove"
    flatpak list --system --app --columns=application 2>/dev/null | grep -qx "play.$appid" && bad "flatpak still lists play.$appid" || ok "flatpak no longer lists play.$appid"
    grep -q "\"$appid\"" "$state/state/installed.json" && bad "state/installed.json still has $appid" || ok "the installed build is forgotten"
    [ -z "$(flatpak override --system --show "play.$appid" 2>&1)" ] && ok "the removal left no override" || bad "the override outlived the app: $(override_text "play.$appid")"
    python3 - "$state/state/jobs" "$3" <<'PY' && ok "the job table records kind remove, phase removing, ok" || bad "state/jobs has no finished remove job $3"
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    j = json.loads(line)
    if j.get("job") == sys.argv[2] and (j.get("kind"), j.get("phase"), j.get("status")) == ("remove", "removing", "ok"):
        sys.exit(0)
sys.exit(1)
PY
    set -- $(remove_wait "play.$appid")
    [ "$1" = unknown-app ] && ok "a second Remove is unknown-app" || bad "the second Remove: $*"
    # What was removed installs again.
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the package installs again after Remove" || bad "the reinstall: $got"
    # A failed call lists nothing withdrawn too: its status must be ok first (RUY-923 review).
    out="$(store_call GetPermissions s "play.$appid")"
    if [ "$(echo "$out" | parse status)" != ok ]; then
        bad "GetPermissions after the reinstall: $out"
    elif echo " $(echo "$out" | parse keys withdrawn) " | grep -q ' network '; then
        bad "the reinstall starts with the network withdrawn"
    else
        ok "the reinstall starts with nothing withdrawn"
    fi
}

# --- launch and launch-windows (RUY-902) ---------------------------------------------------------------
sesvc=org.ruyaos.Session1
sepath=/org/ruyaos/Session1
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
# What the cleanup undoes: the profile the check made (lcreated, with the admin ladmin that makes it
# deletable), the monitor, the running instance, the SDL override, the removed routes. lzip is the
# package launch_run installed (launch-windows makes its update from it).
lprof=""; ladmin=""; lcreated=""; lmon=""; linst=""; lover=""; lrouted=0; lzip=""; lpad=""; lwatch=""; lchoice=""

list_profiles() { busctl --system call "$psvc" "$ppath" "$psvc" ListProfiles | grep -o '"p[0-9]*"' | tr -d '"'; }

# launch_profile: the profile the game runs as (lprof): the VM's first one, else an admin and a standard
# profile made here, as vm-sample-check.sh does (the last admin cannot be deleted, so the cleanup removes
# the standard one only).
launch_profile() {
    lprof="$(list_profiles | head -1)"
    if [ -z "$lprof" ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "" "" "Check Admin" admin 1234 >/dev/null
        ladmin="$(list_profiles | head -1)"
        busctl --system call "$psvc" "$ppath" "$psvc" CreateProfile sssss "$ladmin" 1234 "Check Kid" standard "" >/dev/null
        lprof="$(list_profiles | grep -vx "$ladmin" | head -1)"
        lcreated="$lprof"
    fi
    [ -n "$lprof" ] && ok "profile $lprof (made by the check: ${lcreated:-no})" || { bad "cannot find or make a profile to run the game as"; return 1; }
}

# sign_in <profile>: a profile without a PIN, else with RUYA_PIN when it is set (the Dell's profile),
# else with 1234 (what vm-goto.ps1 makes), the order dell-hub-check.sh signin uses. The PIN is only
# ever an argument of busctl: never echoed (the failure line prints the reply), and no `set -x` here.
sign_in() {
    local out pin
    for pin in "" ${RUYA_PIN:+"$RUYA_PIN"} 1234; do
        out="$(busctl --system call "$psvc" "$ppath" "$psvc" SwitchTo ss "$1" "$pin")"
        case "$out" in 'suu "ok"'*) return 0 ;; esac
    done
    echo "SwitchTo $1: $out"; return 1
}

# Session1's signals into $work/signals.log (read with `signals`).
start_monitor() {
    : > "$work/signals.log"
    busctl --system --json=short monitor "$sesvc" >> "$work/signals.log" 2>&1 &
    lmon=$!
    sleep 2
}

# wait_signal <member> <app id> <n> <seconds>: the fields of the n-th such signal, once it came.
wait_signal() {
    local i=0 line
    while [ "$i" -lt "$4" ]; do
        line="$(signals "$work/signals.log" "$1" "$2" | sed -n "${3}p")"
        [ -n "$line" ] && { echo "$line"; return 0; }
        sleep 1; i=$((i + 1))
    done
    return 1
}

# start_app <app id> <n>: Session1.Launch as lprof; linst is the instance once it answered ok and the
# n-th AppStarted of the app came.
start_app() {
    local out
    out="$(as_shell busctl --system call "$sesvc" "$sepath" "$sesvc" Launch ss "$1" "$lprof")"
    linst="$(echo "$out" | sed -n 's/^ss "ok" "\(.*\)"$/\1/p')"
    [ -n "$linst" ] && ok "Session1.Launch of $1 answered ok ($linst)" || { bad "Launch of $1: $out"; return 1; }
    wait_signal AppStarted "$1" "$2" 60 >/dev/null && ok "AppStarted arrived (launch $2)" || { bad "no AppStarted within 60 s (launch $2)"; return 1; }
}

# stop_app: Session1.Stop of the running instance (linst).
stop_app() {
    case "$(as_shell busctl --system call "$sesvc" "$sepath" "$sesvc" Stop s "$linst")" in
        's "ok"') ok "Stop answered ok" ;;
        *) bad "Stop of $linst" ;;
    esac
}

# expect_exit <app id> <n> <seconds> <pattern> <what>: the n-th AppExited of the app comes within
# <seconds> and its "<exit code> <reason>" matches the glob <pattern>.
expect_exit() {
    local line rest
    line="$(wait_signal AppExited "$1" "$2" "$3")" || { bad "$5: no AppExited within $3 s"; return 1; }
    linst=""
    rest="${line#* }"
    case "$rest" in
        $4) ok "$5: AppExited $rest" ;;
        *) bad "$5: AppExited '$rest', want '$4'"; return 1 ;;
    esac
}

# kv <file> <key>: the value of "<key>=<value>" in a text file (a save, check.txt); empty when none.
# CR is dropped: a Windows program writes its text files with CR LF (check.exe's check.txt, RUY-999).
kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tr -d '\r' | head -1; }

# wait_kv <file> <key> <value> <seconds>
wait_kv() {
    local i=0
    while [ "$i" -lt "$4" ]; do
        [ "$(kv "$1" "$2")" = "$3" ] && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# Spike Q4: a 32-bit program in a sandbox without multiarch is killed with SIGSYS by Flatpak's seccomp
# filter; the journal would show the signal or the audit record (sig=31).
sigsys_checks() {
    local hits
    hits="$(journalctl --since "$since" -o cat 2>/dev/null | grep -aE 'SIGSYS|signal=SYS|status=31/SYS|sig=31 ' | head -3)"
    [ -z "$hits" ] && ok "no SIGSYS (seccomp kill) in the journal during the check" || bad "SIGSYS in the journal: $hits"
}

# launch: the native sample as a profile.
launch_checks() {
    local app="play.$appid" user="ruya-$lprof" data slot got
    data="/var/home/$user/.var/app/$app/data"
    slot="$data/saves/slot1.sav"
    rm -rf "/var/home/$user/.var/app/$app"
    flatpak override --system --env=SDL_VIDEODRIVER=dummy --env=SDL_AUDIODRIVER=dummy "$app" && lover="$app"
    start_monitor
    echo "--- first launch: a new game"
    start_app "$app" 1 || return
    wait_kv "$slot" plays 1 60 && ok "the save exists: $slot (plays=1)" || bad "no save with plays=1 within 60 s"
    [ "$(stat -c %U "$slot" 2>/dev/null)" = "$user" ] && ok "the save belongs to $user" || bad "owner of the save: $(stat -c %U "$slot" 2>&1)"
    stop_app
    expect_exit "$app" 1 60 '*quit' "Stop ends the game" || return
    got="$(launcher_state "$data/.ruya-play/state.json")"
    case "$got" in *" runner=none") ok "the launcher wrote its status file for a native game ($got)" ;; *) bad "the launcher's status file: $got" ;; esac
    echo "--- second launch: it loads the save"
    start_app "$app" 2 || return
    wait_kv "$slot" plays 2 60 && ok "plays=2: the first save was loaded and counted on" || bad "plays is $(kv "$slot" plays), not 2"
    stop_app
    expect_exit "$app" 2 60 '*quit' "the second Stop ends the game" || return
    avc_checks
    sigsys_checks
}

# launch-windows: the Windows sample, offline, with a 32-bit command-line program.
launch_windows_checks() {
    local app="play.$appid" user="ruya-$lprof" data pdir report runner perms want got ref game module next
    data="/var/home/$user/.var/app/$app/data"
    # ${prefix} of a Proton runner is <data>/proton/pfx (05 section 6.2.1); check.exe saves in Documents.
    report="$data/proton/pfx/drive_c/users/steamuser/Documents/Hello Play/check.txt"
    # ${game}, the profile's game tree of run.writable (ADR-040, RUY-1019); check.exe runs from Program/.
    game="$data/.ruya-play/game"
    echo "--- the platform and the sandbox"
    runner="$(system_runner /usr/lib/ruyaos/play/runners)" && ok "the image ships the GE-Proton runner $runner" \
        || { bad "no proton-ge runner.json under /usr/lib/ruyaos/play/runners"; return; }
    [ -x /usr/lib/ruyaos/play/launcher/bin/ruya-play-launch ] && ok "the launcher is in the image" || bad "no /usr/lib/ruyaos/play/launcher/bin/ruya-play-launch"
    module_check ruya_play_runners
    runner_lib_checks "$app" "$(system_runner_dir /usr/lib/ruyaos/play/runners)"
    ref="$(compat_i386 "$app")" && ok "the 32-bit loader is installed for $app: $ref" \
        || bad "$app's runtime has no 32-bit loader: ${ref:-no runtime} (Compat.i386) is not installed"
    perms="$(flatpak info --system --show-permissions "$app" 2>&1 | perm_lines)"
    echo "$perms" | grep -qx '\[Context\] features=multiarch' && ok "$app may run 32-bit code (features=multiarch)" || bad "$app has no multiarch permission: $perms"
    echo "$perms" | grep -q 'shared=network' && bad "$app has the network permission" || ok "$app has no network permission"
    rm -rf "/var/home/$user/.var/app/$app"
    sign_in "$lprof" && ok "$lprof signed in" || { bad "cannot sign in $lprof"; return; }
    start_monitor
    echo "--- offline"
    # The flag first: if `on` stops half-way, the cleanup still puts back what it took.
    lrouted=1
    offline on "$work" || { bad "the default routes could not be taken away"; return; }
    ip route get 1.1.1.1 >/dev/null 2>&1 && bad "the guest still has a route to the internet" || ok "the guest has no route to the internet"
    # RUY-1039: a "physical" pad is held, so the shell's route makes the virtual pad when the game starts; a
    # background watcher looks for the winebus winedevice holding that pad's event node while the game runs.
    pdir="$(dirname "$0")"
    if [ -f "$pdir/vm-input-probe.py" ]; then
        python3 "$pdir/vm-input-probe.py" pad 1200 --join "$lprof" > "$work/pad.log" 2>&1 &
        lpad=$!
        watch_winebus "$work/winebus.txt" 600 &
        lwatch=$!
    else
        bad "no $pdir/vm-input-probe.py: copy it next to this script (the winebus pad check)"
    fi
    echo "--- first launch: a new prefix, the setup step, check.exe"
    start_app "$app" 1 || return
    # The first launch makes the prefix (GE-Proton) and runs the setup step: minutes in a VM.
    expect_exit "$app" 1 600 '0 quit' "check.exe ends by itself" || return
    if [ -n "$lwatch" ]; then
        # The game ended by itself: the watcher either found the pad in a winebus process, or never will.
        kill "$lwatch" 2>/dev/null; lwatch=""
        got="$(cat "$work/winebus.txt" 2>/dev/null)"
        [ -n "$got" ] && ok "the winebus winedevice (pid ${got% *}) holds the virtual pad's ${got#* }" \
            || bad "no winebus winedevice held a virtual pad's /dev/input/event* during the launch ($(cat "$work/pad.log" 2>&1 | head -2 | tr '\n' ' '))"
    fi
    if [ ! -f "$report" ]; then
        bad "no $report; check.txt is at: $(find "$data" -name check.txt 2>/dev/null | head -3)"
        return
    fi
    for want in launches=1 pointer_bits=32 wow64=1 network=closed; do
        [ "$(kv "$report" "${want%%=*}")" = "${want#*=}" ] && ok "check.txt says $want" || bad "check.txt says ${want%%=*}=$(kv "$report" "${want%%=*}"), want $want"
    done
    # The game tree: check.exe runs from it, finds its folder there and writes beside itself.
    module="$(module_path "$report")"
    case "$module" in
        */.var/app/"$app"/data/.ruya-play/game/Program/check.exe) ok "GetModuleFileNameW gives the program in \${game}: $module" ;;
        *) bad "check.exe's module path is '$(kv "$report" module)' (${module:-not on Z:}), not \${game}/Program/check.exe" ;;
    esac
    [ "$(kv "$report" edition)" = 1 ] && ok "check.exe read check.ini beside its program (edition=1)" || bad "check.txt says edition=$(kv "$report" edition), want 1 (check.ini beside the program)"
    [ "$(kv "$report" beside)" = 1 ] && [ "$(kv "$game/Program/beside.txt" launches)" = 1 ] && ok "check.exe wrote beside.txt next to itself, in \${game}/Program (launches=1)" \
        || bad "beside.txt: check.txt says beside=$(kv "$report" beside), $game/Program/beside.txt says launches=$(kv "$game/Program/beside.txt" launches)"
    want="epoch=1 setup_done=first-run runner=system/$runner game=1"
    got="$(launcher_state "$data/.ruya-play/state.json")"
    [ "$got" = "$want" ] && ok "the launcher's status file: $got" || bad "the launcher's status file says '$got', want '$want'"
    echo "--- second launch: the save in the prefix survives"
    start_app "$app" 2 || return
    expect_exit "$app" 2 300 '0 quit' "check.exe ends by itself again" || return
    [ "$(kv "$report" launches)" = 2 ] && ok "launches=2: the save in the prefix survived the relaunch" || bad "launches is $(kv "$report" launches), not 2"
    [ "$(kv "$report" network)" = closed ] && ok "the second launch had no network either" || bad "the second launch reached the network"
    got="$(launcher_state "$data/.ruya-play/state.json")"
    [ "$got" = "$want" ] && ok "the status file is the same after the relaunch (the setup step ran once)" || bad "the launcher's status file after the relaunch says '$got'"
    [ "$(kv "$game/Program/beside.txt" launches)" = 2 ] && [ "$(kv "$report" beside)" = 2 ] && ok "beside.txt survived the relaunch (launches=2)" || bad "beside.txt after the relaunch says launches=$(kv "$game/Program/beside.txt" launches)"
    echo "--- an update: the next build, its check.ini changed"
    next="$(bump_build "$lzip" "$work/launchwindows-next.play.zip" Program/check.ini 'edition=2')" || { bad "bump_build: no next build of $lzip"; return; }
    install -m 0600 "$work/launchwindows-next.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "build $next installs over the first (developer mode)" || { bad "the update to build $next: $got"; return; }
    start_app "$app" 3 || return
    expect_exit "$app" 3 300 '0 quit' "check.exe ends by itself after the update" || return
    [ "$(kv "$report" edition)" = 2 ] && ok "edition=2: the check.ini the game never changed was replaced by build $next's" || bad "check.txt says edition=$(kv "$report" edition) after the update, want 2"
    [ "$(kv "$report" beside)" = 3 ] && [ "$(kv "$game/Program/beside.txt" launches)" = 3 ] && ok "beside.txt survived the update (launches=3): what the game wrote is kept" \
        || bad "beside.txt after the update: check.txt says beside=$(kv "$report" beside), the file says launches=$(kv "$game/Program/beside.txt" launches)"
    [ "$(kv "$report" launches)" = 3 ] && ok "the save in the prefix survived the update (launches=3)" || bad "launches is $(kv "$report" launches) after the update, not 3"
    want="epoch=1 setup_done=first-run runner=system/$runner game=$next"
    got="$(launcher_state "$data/.ruya-play/state.json")"
    [ "$got" = "$want" ] && ok "the status file records the new build's tree: $got" || bad "the launcher's status file after the update says '$got', want '$want'"
    [ ! -e "$data/.ruya-play/game.new" ] && ok "no rebuild is left half-done (no game.new)" || bad "$data/.ruya-play/game.new is still there after the update"
    offline off "$work" && lrouted=0 || bad "the default routes could not be restored"
    avc_checks
    sigsys_checks
}

# launch_run <id part> <package function> <checks function>: install the sample under its own id, with
# the package function (with_id or windows_pkg), then run the checks as a profile.
launch_run() {
    local part="$1" build="$2" checks="$3" got
    dev_mode true >/dev/null
    appid="$(pkg_id "$appid" "$part")" || { bad "no $part id for $appid"; return 1; }
    lzip="$work/$part.play.zip"
    "$build" "$zip" "$lzip" "$appid" || { bad "$build: no copy of the sample with the id $appid"; return 1; }
    mkdir -p "$state/incoming"
    install -m 0600 "$work/$part.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the sample installs (developer mode)" || { bad "the sample: $got"; return 1; }
    launch_profile || return 1
    "$checks"
}

# --- bundled (RUY-1248): which runner a launch uses, 05 section 6.2 -----------------------------------------
lsvc=org.ruyaos.Library1
lpath=/org/ruyaos/Library1
runners_dir=/usr/lib/ruyaos/play/runners

bundled_newest_pkg() { bundled_pkg "$1" "$2" "$3" newest 0 "$runners_dir"; }

# resolved <app> <choice> <want> <seconds>: Library1 ResolveRunner of the app for the choice, as `parse
# resolution` words it; asked again for up to <seconds> until it is <want> (the library reads Flatpak's
# installation after an install or an update, a moment later). Prints the last answer.
resolved() {
    local i=0 got
    while :; do
        got="$(as_shell busctl --system --json=short call "$lsvc" "$lpath" "$lsvc" ResolveRunner ss "flatpak:$1" "$2" | parse resolution)"
        { [ "$got" = "$3" ] || [ "$i" -ge "$4" ]; } && break
        sleep 1; i=$((i + 1))
    done
    echo "$got"
}

# set_choice <app> <choice>: the signed-in profile's runner choice for the app (Library1 SetRunnerChoice); prints
# busctl's answer, `s "ok"`. It runs in a command substitution (a subshell), so the caller records the choice
# for the cleanup, which puts it back to package, before it calls this.
set_choice() {
    as_shell busctl --system call "$lsvc" "$lpath" "$lsvc" SetRunnerChoice sss "$lprof" "flatpak:$1" "$2"
}

# game_runs <marker>: how often the bundled `proton` script was started for the game (its first argument is
# waitforexitandrun; the setup step's `run` does not count); 0 without the file.
game_runs() {
    local n
    n="$(grep -c ' waitforexitandrun$' "$1" 2>/dev/null)"
    echo "${n:-0}"
}

# expect_runner <runner> <data> <what>: the launcher's status file (05 section 6.3, step 7) names <runner>,
# "<source>/<family>/<version>", as the runner of the last launch, the prefix made once.
expect_runner() {
    local got
    got="$(launcher_state "$2/.ruya-play/state.json")"
    got="${got% game=*}"
    [ "$got" = "epoch=1 setup_done=first-run runner=$1" ] && ok "$3: the status file says the runner was $1" \
        || bad "$3: the status file says '$got', want 'epoch=1 setup_done=first-run runner=$1'"
}

# bundled: three launches of one app and what each ran. The image's runner is `sys` (<family>/<version>), the
# bundled copy `bundled/<family>/<version above it>`.
bundled_checks() {
    local app="play.$appid" user="ruya-$lprof" data report marker sys bundled got ref
    data="/var/home/$user/.var/app/$app/data"
    report="$data/proton/pfx/drive_c/users/steamuser/Documents/Hello Play/check.txt"
    marker="$data/bundled-runner-ran"
    echo "--- the runners: the image's, and the bundled copy one version above it"
    sys="$(system_runner "$runners_dir")" && ok "the image ships the GE-Proton runner $sys" || { bad "no proton-ge runner.json under $runners_dir"; return; }
    bundled="bundled/${sys%%/*}/$(bundled_version "$runners_dir")" || { bad "no version above the image's $sys"; return; }
    ok "the package bundles ${bundled#bundled/}, source newest"
    ref="$(compat_i386 "$app")" && ok "the 32-bit loader is installed for $app: $ref" \
        || bad "$app's runtime has no 32-bit loader: ${ref:-no runtime} (Compat.i386) is not installed"
    rm -rf "/var/home/$user/.var/app/$app"
    sign_in "$lprof" && ok "$lprof signed in" || { bad "cannot sign in $lprof"; return; }
    start_monitor
    echo "--- ResolveRunner: the package's default and the System choice"
    got="$(resolved "$app" package "$bundled" 60)"
    [ "$got" = "$bundled" ] && ok "ResolveRunner(package): $got, the higher version wins under source newest" || bad "ResolveRunner(package) says '$got', want $bundled"
    got="$(resolved "$app" system "system/$sys" 5)"
    [ "$got" = "system/$sys" ] && ok "ResolveRunner(system): $got, the image's runner" || bad "ResolveRunner(system) says '$got', want system/$sys"
    echo "--- first launch: no choice of the player, the bundled copy runs (a new prefix, the setup step: minutes)"
    start_app "$app" 1 || return
    expect_exit "$app" 1 600 '0 quit' "check.exe ends by itself" || return
    expect_runner "$bundled" "$data" "first launch"
    [ "$(game_runs "$marker")" = 1 ] && grep -qx "${bundled##*/} waitforexitandrun" "$marker" \
        && ok "the bundled runner's own script started the game once (${bundled##*/})" \
        || bad "the bundled script ran the game $(game_runs "$marker") times, want once: $(tr '\n' '|' < "$marker" 2>&1)"
    [ "$(kv "$report" launches)" = 1 ] && ok "check.exe ran on it (launches=1)" || bad "check.txt says launches=$(kv "$report" launches), not 1 ($report)"
    echo "--- the player's choice System (Library1 SetRunnerChoice): the image's runner"
    lchoice="$app"
    got="$(set_choice "$app" system)"
    [ "$got" = 's "ok"' ] && ok "SetRunnerChoice system: ok" || { bad "SetRunnerChoice system: $got"; return; }
    start_app "$app" 2 || return
    expect_exit "$app" 2 300 '0 quit' "check.exe ends by itself on the system runner" || return
    expect_runner "system/$sys" "$data" "second launch (System)"
    [ "$(game_runs "$marker")" = 1 ] && ok "the bundled script did not run again: the image's GE-Proton started the game" \
        || bad "the bundled script ran the game $(game_runs "$marker") times after the System choice, want still once"
    [ "$(kv "$report" launches)" = 2 ] && ok "check.exe ran on it (launches=2)" || bad "check.txt says launches=$(kv "$report" launches), not 2"
    echo "--- the next build with source: bundled: the System choice does not apply (05 section 6.2)"
    bundled_pkg "$zip" "$work/bundled-only.play.zip" "$appid" bundled 1 "$runners_dir" || { bad "bundled_pkg: no source bundled copy of the sample"; return; }
    install -m 0600 "$work/bundled-only.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the source bundled build installs over the first" || { bad "the update to source bundled: $got"; return; }
    got="$(as_shell busctl --system call "$lsvc" "$lpath" "$lsvc" GetRunnerChoice ss "$lprof" "flatpak:$app")"
    [ "$got" = 'ss "ok" "system"' ] && ok "the profile's choice is still System" || bad "GetRunnerChoice: $got"
    got="$(resolved "$app" system "$bundled fallback" 60)"
    [ "$got" = "$bundled fallback" ] && ok "ResolveRunner(system) of source bundled: $got, the choice cannot be honoured" || bad "ResolveRunner(system) says '$got', want '$bundled fallback'"
    start_app "$app" 3 || return
    expect_exit "$app" 3 300 '0 quit' "check.exe ends by itself on the bundled copy again" || return
    expect_runner "$bundled" "$data" "third launch (source bundled, System chosen)"
    [ "$(game_runs "$marker")" = 2 ] && ok "the bundled script started the game again although the player chose System" \
        || bad "the bundled script ran the game $(game_runs "$marker") times, want twice"
    [ "$(kv "$report" launches)" = 3 ] && ok "check.exe ran on it (launches=3)" || bad "check.txt says launches=$(kv "$report" launches), not 3"
    avc_checks
    sigsys_checks
}

# The cleanup's part: stop what the modes started, give back the routes, remove the profile's data and
# the profile the check made.
launch_cleanup() {
    [ -n "$lmon" ] && kill "$lmon" 2>/dev/null
    [ -n "$lwatch" ] && kill "$lwatch" 2>/dev/null
    [ -n "$lpad" ] && kill "$lpad" 2>/dev/null
    if [ "$lrouted" = 1 ]; then
        offline off "$work" && lrouted=0 || bad "the default routes could not be restored: put them back with ip route replace (the saved routes are in $work)"
    fi
    if [ -n "$linst" ]; then
        as_shell busctl --system call "$sesvc" "$sepath" "$sesvc" Stop s "$linst" >/dev/null 2>&1
        sleep 3
    fi
    [ -n "$lover" ] && flatpak override --system --reset "$lover" >/dev/null 2>&1
    # The profile's runner choice (bundled): back to package, before the app goes (the library knows no choice for
    # an app that is not installed, and the profile is a real one).
    [ -n "$lchoice" ] && as_shell busctl --system call "$lsvc" "$lpath" "$lsvc" SetRunnerChoice sss "$lprof" "flatpak:$lchoice" package >/dev/null 2>&1
    [ -n "$lprof" ] && [ -n "${appid:-}" ] && rm -rf "/var/home/ruya-$lprof/.var/app/play.$appid"
    if [ -n "$lcreated" ]; then
        busctl --system call "$psvc" "$ppath" "$psvc" Lock >/dev/null 2>&1
        busctl --system call "$psvc" "$ppath" "$psvc" DeleteProfile sss "$ladmin" 1234 "$lcreated" >/dev/null 2>&1
    fi
}

cleanup() {
    launch_cleanup
    [ -n "${listener:-}" ] && kill "$listener" 2>/dev/null
    [ -n "${appid:-}" ] && flatpak override --system --reset "play.$appid" >/dev/null 2>&1
    local removed=0
    [ -n "${appid:-}" ] && { remove_app "play.$appid" || removed=1; }
    [ -n "${before_dev:-}" ] && dev_mode "$before_dev" >/dev/null 2>&1
    umount "$usb" "$loose" 2>/dev/null
    rmdir "$usb" "$loose" 2>/dev/null
    rm -rf "$work" "$state/incoming/vm-play-check.play.zip"
    # An exit inside the EXIT trap sets the script's status.
    [ "$removed" = 0 ] || exit 1
}

if [ "$mode" = removeapp ]; then
    remove_app "${2:?play.<id>}"
    exit $?
fi

[ -f "$zip" ] || { echo "FAIL: no package at $zip (build it as scripts/ci-samples-linux.sh does)"; exit 1; }
systemctl is-active -q ruya-play.service && ok "ruya-play.service is active" || bad "ruya-play.service is not active"
# RUY-867: RUY-866 moved staging/ and inspect/ to ruya-play-work; tmpfiles.d/ruya-play.conf removes the
# old folders at boot, so an upgraded console has none.
for old in staging inspect; do
    [ ! -e "$state/$old" ] && ok "the old $state/$old is gone" || bad "the old $state/$old still exists (tmpfiles R line)"
done

if [ "$mode" = helper ]; then
    mkdir -p "$state/incoming"
    install -m 0600 "$zip" "$state/incoming/vm-play-check.play.zip"
    helper_checks "$state/incoming/vm-play-check.play.zip"
    st="$(inspect_clean "$state/incoming/vm-play-check.play.zip" "")"
    [ "$st" = ok ] && ok "Inspect of an incoming/ file (root 0600) is ok, no internal fault" || bad "Inspect of an incoming/ file: $st"
    rm -f "$state/incoming/vm-play-check.play.zip"
    ls /var/lib/private 2>/dev/null | grep -q '^ruya-play-helper-' && bad "a helper state folder was left" || ok "no helper state folder is left"
    avc_checks
    [ "$fail" = 0 ] && echo "vm-play-check helper: PASS" || echo "vm-play-check helper: FAIL"
    exit "$fail"
fi

chmod +x "$pack" 2>/dev/null  # scp from Windows drops the exec bit
[ -x "$pack" ] || { echo "FAIL: no ruya-pack at $pack"; exit 1; }
trap cleanup EXIT
appid="$(id_of "$zip")"
before_dev="$(call GetDeveloperMode | parse status)"
mkdir -p "$work" "$usb" "$loose"

if [ "$mode" = verify ]; then
    dev_mode true >/dev/null
    appid="$(pkg_id "$appid" verify)" || { bad "no verify id for $appid"; exit 1; }
    with_id "$zip" "$work/verify.play.zip" "$appid" || { bad "with_id: no copy of the sample with the id $appid"; exit 1; }
    mkdir -p "$state/incoming"
    install -m 0600 "$work/verify.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the sample installs (developer mode)" || bad "the sample: $got"
    [ "$got" = ok ] && verify_checks
    [ "$fail" = 0 ] && echo "vm-play-check verify: PASS" || echo "vm-play-check verify: FAIL"
    exit "$fail"
fi

if [ "$mode" = remove ]; then
    dev_mode true >/dev/null
    appid="$(pkg_id "$appid" remove)" || { bad "no remove id for $appid"; exit 1; }
    with_id "$zip" "$work/id.play.zip" "$appid" || { bad "with_id: no copy of the sample with the id $appid"; exit 1; }
    asks_network "$work/id.play.zip" "$work/remove.play.zip" || { bad "asks_network: no copy of the sample asking for the network"; exit 1; }
    mkdir -p "$state/incoming"
    install -m 0600 "$work/remove.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the sample installs (developer mode)" || bad "the sample: $got"
    [ "$got" = ok ] && remove_checks
    [ "$fail" = 0 ] && echo "vm-play-check remove: PASS" || echo "vm-play-check remove: FAIL"
    exit "$fail"
fi

# --- RUY-854: the console's permission list (Store1, RUY-744) for a .play app ----------------------
# A new sandbox each time: "net=N connect=yes|no" (the port is the listener's).
sandbox_net() { # <app> <port>
    flatpak run --system --command=bash "$1" -c "$NET_PROBE" probe "$2" 2>/dev/null | tr '\n' ' '
}
listener=""
# A listener on the host's loopback that accepts and closes; prints nothing, sets $port.
start_listener() {
    python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
print(s.getsockname()[1], flush=True)
while True:
    c, _ = s.accept()
    c.close()
' > "$work/listener.port" &
    listener=$!
    n=0
    while [ ! -s "$work/listener.port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    port="$(cat "$work/listener.port")"
    [ -n "$port" ]
}
permission_list_checks() { # <flatpak app id>
    local papp="$1" out now meta
    echo "--- RUY-854: the permission list covers the .play app"
    # No ListInstalled first: the service must know an app that ruya-play installed after it started.
    out="$(store_call GetPermissions s "$papp")"
    echo "GetPermissions: $out"
    [ "$(echo "$out" | parse status)" = ok ] && ok "Store1.GetPermissions answers for $papp (not unknown-app)" || bad "GetPermissions: $out"
    echo " $(echo "$out" | parse keys effective) " | grep -q ' network ' && ok "the network is among what the app has" || bad "no network in the effective set: $out"
    echo " $(echo "$out" | parse keys withdrawable) " | grep -q ' network ' && ok "the network is withdrawable" || bad "network is not withdrawable: $out"
    [ -z "$(echo "$out" | parse keys withdrawn)" ] && ok "nothing is withdrawn yet" || bad "withdrawn before any change: $out"
    store_call ListInstalled | grep -q "\"$papp\"" && ok "ListInstalled lists $papp" || bad "ListInstalled does not list $papp"

    start_listener || { bad "no listener on the loopback"; return; }
    now="$(sandbox_net "$papp" "$port")"
    echo "sandbox before: $now"
    case "$now" in *"connect=yes"*) ok "the sandbox connects to the host's listener before any withdrawal";; *) bad "the sandbox cannot connect before a withdrawal: '$now'";; esac

    # The deployment's own metadata: `--show-permissions` is that merged with the override, so it
    # lacks network after a withdrawal by design (RUY-1002).
    meta="$(flatpak info --system --show-metadata "$papp" 2>&1)"
    [ "$(store_call WithdrawPermission ss "$papp" network | parse status)" = ok ] && ok "WithdrawPermission network by root" || bad "WithdrawPermission network"
    flatpak override --system --show "$papp" | grep -q '^shared=!network;' && ok "the override says shared=!network" || bad "override: $(override_text "$papp")"
    echo " $(store_call GetPermissions s "$papp" | parse keys withdrawn) " | grep -q ' network ' && ok "GetPermissions reports network withdrawn" || bad "GetPermissions after the withdrawal"
    [ "$(flatpak info --system --show-metadata "$papp" 2>&1)" = "$meta" ] && ok "the generated metadata is unchanged (the withdrawal is the override alone)" || bad "the withdrawal changed the app's metadata"
    if flatpak info --system --show-permissions "$papp" 2>&1 | grep -qx 'shared=.*network'; then
        bad "the merged permissions still show network after the withdrawal"
    else
        ok "the merged permissions (metadata and override) no longer show network"
    fi
    now="$(sandbox_net "$papp" "$port")"
    echo "sandbox after: $now"
    case "$now" in *"connect=no"*) ok "the next launch cannot connect: the network is withdrawn";; *) bad "the sandbox still connects after the withdrawal: '$now'";; esac

    [ "$(store_call ResetPermissions s "$papp" | parse status)" = ok ] && ok "ResetPermissions by root" || bad "ResetPermissions"
    [ -z "$(flatpak override --system --show "$papp")" ] && ok "the reset left no override" || bad "an override is left: $(override_text "$papp")"
    [ "$(flatpak info --system --show-metadata "$papp" 2>&1)" = "$meta" ] && ok "the metadata is unchanged after the reset" || bad "the reset changed the app's metadata"
    now="$(sandbox_net "$papp" "$port")"
    case "$now" in *"connect=yes"*) ok "the network is back after the reset";; *) bad "the network did not come back: '$now'";; esac
    kill "$listener" 2>/dev/null
    listener=""
}

if [ "$mode" = perms ]; then
    dev_mode true >/dev/null
    appid="$(pkg_id "$appid" perms)" || { bad "no perms id for $appid"; exit 1; }
    with_id "$zip" "$work/id.play.zip" "$appid" || { bad "with_id: no copy of the sample with the id $appid"; exit 1; }
    asks_network "$work/id.play.zip" "$work/perms.play.zip" || { bad "asks_network: no copy of the sample asking for the network"; exit 1; }
    mkdir -p "$state/incoming"
    install -m 0600 "$work/perms.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the sample asking for network, multiarch and gamemode installs (developer mode)" || bad "the perms package: $got"
    have="$(flatpak info --system --show-permissions "play.$appid" 2>&1 | perm_lines)"
    if [ "$have" = "$PERMS_WANT" ]; then
        ok "flatpak info --show-permissions play.$appid is exactly the mapped set"
    else
        bad "play.$appid's permissions differ from 05 section 8's mapping"
        diff <(echo "$PERMS_WANT") <(echo "$have") | sed 's/^/    /'
    fi
    trust="/var/lib/flatpak/app/play.$appid/current/active/files/share/ruyaos/play/trust.json"
    rec="$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
print(r.get("format"), r.get("tier"), r.get("signer_id"), r.get("signer_name"), r.get("store_signed"))
' "$trust" 2>&1)"
    [ "$rec" = "1 unverified None None False" ] && ok "the trust record says format 1, unverified, no signer" || bad "trust.json: $rec"
    [ "$got" = ok ] && permission_list_checks "play.$appid"
    [ "$fail" = 0 ] && echo "vm-play-check perms: PASS" || echo "vm-play-check perms: FAIL"
    exit "$fail"
fi

if [ "$mode" = launch ]; then
    launch_run launch with_id launch_checks
    [ "$fail" = 0 ] && echo "vm-play-check launch: PASS" || echo "vm-play-check launch: FAIL"
    exit "$fail"
fi

if [ "$mode" = launch-windows ]; then
    launch_run launchwindows windows_pkg launch_windows_checks
    [ "$fail" = 0 ] && echo "vm-play-check launch-windows: PASS" || echo "vm-play-check launch-windows: FAIL"
    exit "$fail"
fi

if [ "$mode" = bundled ]; then
    launch_run bundled bundled_newest_pkg bundled_checks
    [ "$fail" = 0 ] && echo "vm-play-check bundled: PASS" || echo "vm-play-check bundled: FAIL"
    exit "$fail"
fi

# The packages: all made from one copy with this run's id, before anything is signed (RUY-879).
appid="$(run_id "$appid")" || { bad "no run id for $appid"; exit 1; }
with_id "$zip" "$work/run.play.zip" "$appid" || { bad "with_id: no copy of the sample with the id $appid"; exit 1; }
cp "$work/run.play.zip" "$work/unsigned.play.zip"
(cd "$work" && "$pack" keygen a >/dev/null && "$pack" keygen b >/dev/null) || bad "ruya-pack keygen"
for k in a b; do
    cp "$work/run.play.zip" "$work/signed-$k.play.zip"
    "$pack" sign "$work/signed-$k.play.zip" --key "$work/$k.key" >/dev/null || bad "ruya-pack sign with key $k"
done
python3 - "$work/signed-a.play.zip" "$work/tampered.play.zip" "$work/bomb.play.zip" <<'PY'
import sys, zipfile
src, tampered, bomb = sys.argv[1:4]
zin = zipfile.ZipFile(src)
with zipfile.ZipFile(tampered, "w", zipfile.ZIP_STORED) as z:
    for i in zin.infolist():
        b = zin.read(i.filename)
        if i.filename.endswith("play.json") and i.filename.count("/") <= 1:
            b = b.rstrip() + b"\n "  # still the same manifest, no longer the signed bytes
        z.writestr(i, b)
zin = zipfile.ZipFile(src)  # re-opened: writestr changed the ZipInfo objects above (Python 3.14: "Overlapped entries")
with zipfile.ZipFile(bomb, "w", zipfile.ZIP_DEFLATED) as z:
    for i in zin.infolist():
        if i.filename.endswith(("play.json", "play.files")):
            z.writestr(i, zin.read(i.filename))
    with z.open("payload/bomb.bin", "w", force_zip64=True) as f:
        chunk = bytes(1 << 20)
        for _ in range(4096):  # 4 GiB of zeros, a few MiB compressed
            f.write(chunk)
PY

# The drives: one as ruya-devices mounts it, one without noexec.
truncate -s 256M "$work/usb.img" && mkfs.vfat -n PLAYCHECK "$work/usb.img" >/dev/null
truncate -s 64M "$work/loose.img" && mkfs.vfat -n PLAYLOOSE "$work/loose.img" >/dev/null
uid="$(id -u ruya-shell)"
mount -o loop,nosuid,nodev,noexec,uid="$uid" "$work/usb.img" "$usb" || bad "mounting the check drive"
mount -o loop,nosuid,nodev,uid="$uid" "$work/loose.img" "$loose" || bad "mounting the loose drive"
cp "$work"/unsigned.play.zip "$work"/signed-a.play.zip "$work"/signed-b.play.zip "$work"/tampered.play.zip "$work"/bomb.play.zip "$usb/"
cp "$work/signed-a.play.zip" "$loose/"
sync

srcs="$(call ListSources | parse sources)"
for p in unsigned signed-a signed-b tampered bomb; do
    echo "$srcs" | grep -qx "$usb/$p.play.zip" && ok "ListSources lists $p.play.zip" || bad "ListSources lacks $p.play.zip: $srcs"
done
echo "$srcs" | grep -q "^$loose/" && bad "ListSources lists a drive mounted without noexec" || ok "ListSources skips a drive mounted without noexec"
st="$(call Inspect s "$loose/signed-a.play.zip" | parse status)"
[ "$st" = unknown-source ] && ok "Inspect on a drive without noexec is unknown-source" || bad "Inspect on a drive without noexec: $st"
st="$(inspect_clean "$usb/signed-a.play.zip" ok)"
[ "$st" = ok ] && ok "Inspect of a USB package is ok, no internal fault" || bad "Inspect of a USB package: $st"
# RUY-1038: the art Inspect returns is a copy under /run/ruya-play/inspect that only the shell reads
# (the vetted files in ruya-play-work are root's); a profile user is refused.
art="$(call Inspect s "$usb/signed-a.play.zip" | parse artpaths | tr -d '\r')"
[ -n "$art" ] && ok "Inspect of a USB package returns art paths" || bad "Inspect of a USB package returned no art"
for p in $art; do
    case "$p" in /run/ruya-play/inspect/inspect-*/*) ;; *) bad "art path $p is not under /run/ruya-play/inspect"; continue ;; esac
    as_shell head -c 16 "$p" >/dev/null 2>&1 && ok "ruya-shell reads $p" || bad "ruya-shell cannot read $p"
    runuser -u nobody -- head -c 16 "$p" >/dev/null 2>&1 && bad "nobody can read $p" || ok "nobody is refused $p"
done
# RUY-914: Inspect serves signer_name (the manifest's developer name) only beside a verified key.
rec="$(call Inspect s "$usb/signed-a.play.zip")"
name="$(echo "$rec" | parse key signer_name)"; dev="$(echo "$rec" | parse key developer)"
keyid="$(echo "$rec" | parse key signer_key_id)"
if [ -n "$name" ] && [ "$name" = "$dev" ] && [ -n "$keyid" ]; then
    ok "Inspect of a signed package: signer_name is the developer name, with the key"
else
    bad "Inspect of a signed package: signer_name '$name', developer '$dev', key '$keyid'"
fi
name="$(call Inspect s "$usb/unsigned.play.zip" | parse key signer_name)"
[ -z "$name" ] && ok "Inspect of an unsigned package serves no signer_name" || bad "Inspect of an unsigned package: signer_name '$name'"
st="$(call Inspect s /etc/shadow | parse status)"
[ "$st" = unknown-source ] && ok "Inspect of a path that is no candidate is unknown-source" || bad "Inspect /etc/shadow: $st"
st="$(as_shell busctl --system --json=short call "$svc" "$obj" "$svc" Install 'sa{sv}' "$usb/signed-a.play.zip" 0 | parse status)"
[ "$st" = forbidden ] && ok "Install without admin_approved is forbidden" || bad "Install without admin_approved: $st"

refused() { # <name> <package> <status>
    apps_before="$(flatpak list --system --app --columns=application | grep -c '^play\.')"
    got="$(install_wait "$usb/$2.play.zip")"
    [ "$got" = "$3" ] && ok "$1 is $3" || bad "$1: $got (want $3)"
    leftovers && ok "$1: nothing left in staging/" || bad "$1: staging/ is not empty"
    apps_after="$(flatpak list --system --app --columns=application | grep -c '^play\.')"
    [ "$apps_before" = "$apps_after" ] && ok "$1: no app was installed" || bad "$1: the installation changed"
}

dev_mode false >/dev/null
refused "an unsigned package without developer mode" unsigned needs-developer-mode
refused "a package changed after signing" tampered bad-signature
pid="$(pid_of)"
got="$(install_wait "$usb/bomb.play.zip")"
case "$got" in ok|timeout|call-failed) bad "the zip bomb: $got" ;; *) ok "the zip bomb is refused ($got)" ;; esac
[ "$(pid_of)" = "$pid" ] && systemctl is-active -q ruya-play.service && ok "the service survived the bomb" || bad "the service restarted or died on the bomb"
leftovers && ok "the bomb left nothing in staging/" || bad "the bomb left files in staging/"

got="$(install_wait "$usb/signed-a.play.zip")"
[ "$got" = ok ] && ok "the signed sample installs" || bad "the signed sample: $got"
flatpak list --system --app --columns=application | grep -qx "play.$appid" && ok "flatpak list --system has play.$appid" || bad "play.$appid is not in flatpak list --system"
flatpak info --system --show-metadata "play.$appid" 2>/dev/null | grep -q '^command=/app/launcher/bin/ruya-play-launch' && ok "the generated metadata runs the launcher" || bad "the generated metadata has no launcher command"
[ "$(generation "$state/state/installed.json" "$appid")" -ge 1 ] 2>/dev/null && ok "the install stamped a metadata generation" || bad "installed.json has no metadata generation for $appid"
recommit_check "$appid"
n=0; listed=""
while [ "$n" -lt 20 ]; do
    listed="$(as_shell busctl --system --json=short call org.ruyaos.Library1 /org/ruyaos/Library1 org.ruyaos.Library1 ListItems | parse items)"
    echo "$listed" | grep -qx "flatpak:play.$appid" && break
    sleep 1; n=$((n + 1))
done
echo "$listed" | grep -qx "flatpak:play.$appid" && ok "Library1 lists flatpak:play.$appid" || bad "Library1 does not list flatpak:play.$appid (RUY-876: its item ids are flatpak:<id>)"
profile="$(busctl --system call org.ruyaos.Profiles1 /org/ruyaos/Profiles1 org.ruyaos.Profiles1 ListProfiles | grep -o '"p[0-9]*"' | head -1 | tr -d '"')"
if [ -n "$profile" ]; then
    st="$(as_shell busctl --system --json=short call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss "play.$appid" "$profile" | parse status)"
    [ "$st" = ok ] && ok "Session1.Launch starts play.$appid" || bad "Session1.Launch: $st"
else
    echo "SKIP: no profile on this VM: Session1.Launch of play.$appid not run (create one in the shell first; this check creates none)"
fi
refused "the same id signed by another key" signed-b different-developer

mkdir -p "$state/incoming"
install -m 0600 "$work/signed-a.play.zip" "$state/incoming/vm-play-check.play.zip"
st="$(inspect_clean "$state/incoming/vm-play-check.play.zip" "")"
[ "$st" = ok ] && ok "Inspect of a download in incoming/ (root 0600) is ok, no internal fault" || bad "Inspect of a download in incoming/: $st"

helper_checks "$usb/signed-a.play.zip"

if [ -n "${TESTBIN:-}" ]; then
    for t in "$TESTBIN"/toctou-* "$TESTBIN"/modes-* "$TESTBIN"/jobs-*; do
        [ -x "$t" ] || continue
        case "$t" in *.d) continue ;; esac
        "$t" --include-ignored >/dev/null 2>&1 && ok "core test $(basename "$t")" || bad "core test $(basename "$t")"
    done
else
    echo "SKIP: TESTBIN not set: the Unix-only core tests (toctou.rs, modes.rs) did not run here"
fi
avc_checks
webp_checks

[ "$fail" = 0 ] && echo "vm-play-check: PASS" || echo "vm-play-check: FAIL"
exit "$fail"
