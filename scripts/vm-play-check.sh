#!/usr/bin/env bash
# modes: check helper parse perms restart runid verify withid
# Checks ruya-play (org.ruyaos.Play1, RUY-829, the lead's run under RUY-100) inside a running VM,
# as root. Modes:
#   check  (default) every step below
#   withid host fixtures only: `withid <in.zip> <out.zip> <id>` copies a package with the id of its
#          play.json changed (the helper verify and perms use)
#   restart host fixtures only: `restart_service`, the cleanup's last step, exits 1 with a FAIL line
#          when `systemctl restart ruya-play.service` fails
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
#          no store signature
#   runid  host fixtures only: `runid <id>` prints the id check would use for <id>
#   Every mode that installs uses its own package id (RUY-877): "<id>.c<run>" for check (one
#   fresh id per run, RUY-879; its signed-A/B steps need one id within the run, on purpose),
#   "<id>.verify" for verify and "<id>.perms" for perms, written into a copy of the sample's
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
# unknown-source; a download in incoming/ inspects. At exit everything is removed again and the
# service restarts (its start-up reconcile forgets the uninstalled build).
# JSON is parsed by key, never by key order.
set -u
mode="${1:-check}"
zip="${2:-/root/hello-play-native.play.zip}"
pack="${3:-/root/ruya-pack}"
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

# ADR-036: no SELinux denial of PID 1 (init_t) while the check ran. A denied OpenFile= of the
# source shows up only as "missing" (graceful), so the journal is the proof.
avc_checks() {
    [ -n "$(semodule -l 2>/dev/null | grep -x ruya_play_openfile)" ] \
        && ok "the SELinux module ruya_play_openfile is loaded" \
        || bad "the SELinux module ruya_play_openfile is not loaded"
    local denied
    denied="$(journalctl --since "$since" -o cat 2>/dev/null | grep 'avc:  denied' | grep 'scontext=system_u:system_r:init_t')"
    [ -z "$denied" ] && ok "no init_t AVC denial during the check" \
        || bad "init_t AVC denials during the check: $(echo "$denied" | head -3)"
}
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
# The check's last step restarts the service (its start-up reconcile forgets the uninstalled build).
# A service that does not come back would leave the VM without it, so that is a failure of the check.
restart_service() {
    systemctl restart ruya-play.service && return 0
    bad "ruya-play.service did not restart after the check"
    return 1
}

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
elif what == "key":
    rec = data[1] if len(data) > 1 else {}
    print(val(rec.get(arg)) if arg in rec else "")
elif what == "codes":
    rec = data[1] if len(data) > 1 else {}
    for p in (val(rec.get("problems")) or []):
        print(p[0])
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

# with_id <in.zip> <out.zip> <id>: a copy of a package whose top-level play.json carries <id>
# (RUY-877). The sample is unsigned and play.files does not list play.json, so nothing else names
# the id; a signed package would need signing again.
with_id() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys, zipfile
src, out, new_id = sys.argv[1:4]
sample = zipfile.ZipFile(src)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for i in sample.infolist():
        b = sample.read(i.filename)
        if i.filename.endswith("play.json") and i.filename.count("/") <= 1:
            m = json.loads(b)
            m["id"] = new_id
            b = json.dumps(m, indent=2).encode()
        z.writestr(i, b)
PY
}

# run_id <id>: check's package id for this run. The extra part starts with a letter (a part may
# not start with a digit, ruya-play-format check_id) and the pid keeps two runs in one second apart.
run_id() { echo "$1.c$(date +%s)x$$"; }

if [ "$mode" = parse ]; then
    if [ "${2:-}" = perms ]; then
        perm_lines
        exit $?
    fi
    parse "${2:-}" "${3:-}"
    exit $?
fi
if [ "$mode" = restart ]; then
    restart_service
    exit $?
fi
if [ "$mode" = withid ]; then
    with_id "${2:?in.zip}" "${3:?out.zip}" "${4:?id}"
    exit $?
fi
if [ "$mode" = runid ]; then
    run_id "${2:?id}"
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

# Verify <id> and wait for the job; prints "<method status> <job status or ->" (RUY-834).
verify_wait() {
    out="$(call Verify s "$1")" || { echo "call-failed -"; return; }
    st="$(echo "$out" | parse status)"
    [ "$st" = ok ] || { echo "$st -"; return; }
    job="$(echo "$out" | parse second)"
    n=0
    while [ "$n" -lt 300 ]; do
        line="$(call ListJobs | parse job "$job")"
        case "$line" in finished\ *) echo "ok ${line#finished } $job"; return ;; esac
        sleep 1; n=$((n + 1))
    done
    echo "ok timeout $job"
}

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

cleanup() {
    [ -n "${appid:-}" ] && flatpak uninstall --system -y --noninteractive "play.$appid" >/dev/null 2>&1
    [ -n "${before_dev:-}" ] && dev_mode "$before_dev" >/dev/null 2>&1
    umount "$usb" "$loose" 2>/dev/null
    rmdir "$usb" "$loose" 2>/dev/null
    rm -rf "$work" "$state/incoming/vm-play-check.play.zip"
    # An exit inside the EXIT trap sets the script's status.
    restart_service || exit 1
}

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
    appid="$appid.verify"
    with_id "$zip" "$work/verify.play.zip" "$appid" || { bad "with_id: no copy of the sample with the id $appid"; exit 1; }
    mkdir -p "$state/incoming"
    install -m 0600 "$work/verify.play.zip" "$state/incoming/vm-play-check.play.zip"
    got="$(install_wait "$state/incoming/vm-play-check.play.zip")"
    [ "$got" = ok ] && ok "the sample installs (developer mode)" || bad "the sample: $got"
    [ "$got" = ok ] && verify_checks
    [ "$fail" = 0 ] && echo "vm-play-check verify: PASS" || echo "vm-play-check verify: FAIL"
    exit "$fail"
fi

if [ "$mode" = perms ]; then
    dev_mode true >/dev/null
    appid="$appid.perms"
    with_id "$zip" "$work/id.play.zip" "$appid" || { bad "with_id: no copy of the sample with the id $appid"; exit 1; }
    python3 - "$work/id.play.zip" "$work/perms.play.zip" <<'PY'
import json, sys, zipfile
src, out = sys.argv[1:3]
sample = zipfile.ZipFile(src)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for i in sample.infolist():
        b = sample.read(i.filename)
        if i.filename.endswith("play.json") and i.filename.count("/") <= 1:
            m = json.loads(b)
            m["permissions"] = {"network": True, "multiarch": True, "gamemode": True}
            b = json.dumps(m, indent=2).encode()
        z.writestr(i, b)
PY
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
    [ "$fail" = 0 ] && echo "vm-play-check perms: PASS" || echo "vm-play-check perms: FAIL"
    exit "$fail"
fi

# The packages: all made from one copy with this run's id, before anything is signed (RUY-879).
appid="$(run_id "$appid")"
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

[ "$fail" = 0 ] && echo "vm-play-check: PASS" || echo "vm-play-check: FAIL"
exit "$fail"
