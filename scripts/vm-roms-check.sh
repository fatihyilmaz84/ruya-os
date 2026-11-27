#!/usr/bin/env bash
# modes: check facts paths bench setup clean
# needs: profile check facts paths bench
# (the sandboxed client runs as the signed-in profile; vm-queue.ps1 reads this line)
# DRAFT (RUY-1152 spike, ADR-048 A4): the ROM door's read-only fds, end to end, inside a running VM or
# on the Dell, as root, with a profile signed in. Nothing of it is in the image: it sets up throw-away
# pieces and removes them again (mode clean, and at the end of every run):
#   - two system users, ruyaspike-gd (the stand-in for ruya-gamedata) and ruyaspike-door (for
#     ruya-platform under ADR-047), and a collection /var/lib/ruyaspike-roms/nes/<entry>/<files>,
#     directories 0700 ruyaspike-gd, files 0644 (entries: small 64 KiB, big 4 GiB, set of 3, m250 and
#     m300 files, wr 0666, own 0644 owned by the profile user);
#   - a bus policy /etc/dbus-1/system.d/ruyaspike.conf: ruyaspike-gd owns org.ruyaos.SpikeGamedata,
#     only ruyaspike-door (and root) may call its OpenRom; ruyaspike-door owns org.ruyaos.SpikeDoor,
#     whose OpenRom every user may call (the shape of Platform1's public doors);
#   - two transient units running vm-roms-probe.py as those users, the door with ruya-platform.service's
#     hardening, the stand-in with the same plus no access to anything but the collection;
#   - a Flatpak test app whose only bus permission is --system-talk-name=org.ruyaos.SpikeDoor (and
#     host-os:ro for the image's python3), so its calls go through xdg-dbus-proxy.
# Modes:
#   check  (default) every mode below
#   facts  fact 1: the fds arrive in the sandbox and read; /proc/self/fd/N reopens read-only, never for
#          writing (EACCES, and EROFS: the fd carries the stand-in's read-only mount); then (1b) with the
#          collection writable in the stand-in's namespace, the 0666 and profile-owned files show that
#          only the file's own mode stops a write
#   setup  sets the pieces up and leaves them (for a manual look; clean removes them)
#   paths  fact 2: neither the sandbox nor the profile user outside it reaches the collection by path;
#          the door user cannot either; the door may call only OpenRom of the stand-in
#   bench  fact 3: cost per OpenRom, warm (200 calls on one connection) and cold (50 new connections,
#          caches dropped), per hop: stand-in direct, through the door, through the door from the sandbox
#   clean  removes every piece above
set -u
here="$(cd "$(dirname "$0")" && pwd)"
mode="${1:-check}"
gd=org.ruyaos.SpikeGamedata
door=org.ruyaos.SpikeDoor
app=org.ruyaos.SpikeRomClient
rt=org.ruyaos.SpikeRomRuntime
remote=ruyaspike
root=/var/lib/ruyaspike-roms
coll="$root/nes"
bin=/var/lib/ruyaspike-bin
work=/var/tmp/ruyaspike
conf=/etc/dbus-1/system.d/ruyaspike.conf
psvc=org.ruyaos.Profiles1
ppath=/org/ruyaos/Profiles1
fail=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

clean() {
    systemctl stop ruyaspike-door.service ruyaspike-gamedata.service >/dev/null 2>&1
    systemctl reset-failed ruyaspike-door.service ruyaspike-gamedata.service >/dev/null 2>&1
    for id in "$app" "$rt"; do
        flatpak info --system "$id" >/dev/null 2>&1 && flatpak uninstall --system -y --noninteractive "$id" >/dev/null 2>&1
    done
    flatpak remote-delete --system --force "$remote" >/dev/null 2>&1
    rm -f "$conf"
    systemctl reload dbus-broker.service >/dev/null 2>&1
    rm -rf "$root" "$bin" "$work" /var/home/*/.var/app/"$app"
    for u in ruyaspike-door ruyaspike-gd; do
        getent passwd "$u" >/dev/null && userdel "$u" >/dev/null 2>&1
        getent group "$u" >/dev/null && groupdel "$u" >/dev/null 2>&1
    done
    true
}

signed_in() {
    pid="$(busctl --system get-property "$psvc" "$ppath" "$psvc" ActiveProfile 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p')"
    [ -n "$pid" ] && ok "profile $pid is signed in" || { bad "nobody is signed in (sign a profile in first)"; return 1; }
    user="ruya-$pid"
}

entry() { install -d -m 0700 -o ruyaspike-gd -g ruyaspike-gd "$coll/$1"; }
put() { # put <entry> <name> <bytes> [<mode> <owner>]
    head -c "$3" /dev/urandom > "$coll/$1/$2"
    chown "${5:-ruyaspike-gd}:${5:-ruyaspike-gd}" "$coll/$1/$2"; chmod "${4:-0644}" "$coll/$1/$2"
}

# start_gd ro|rw: the stand-in for ruya-gamedata. ro: the collection is on a read-only mount in its
# namespace (ProtectSystem=strict and nothing writable), so every fd it opens lives on that mount;
# rw: ReadWritePaths= on the collection, as a gamedata that also imports and moves files would have.
start_gd() {
    local -a rw=()
    [ "$1" = rw ] && rw=(-p ReadWritePaths="$root")
    systemctl stop ruyaspike-gamedata.service >/dev/null 2>&1
    systemctl reset-failed ruyaspike-gamedata.service >/dev/null 2>&1
    systemd-run --quiet --unit=ruyaspike-gamedata -p Type=dbus -p BusName="$gd" -p User=ruyaspike-gd "${hard[@]}" "${rw[@]}" \
        /usr/bin/python3 -I "$bin/vm-roms-probe.py" gamedata "$coll"
}

# ruya-platform.service's [Service] hardening, as systemd-run properties (both stand-ins get it).
hard=(-p CapabilityBoundingSet= -p ProtectProc=invisible -p ProcSubset=pid -p ProtectSystem=strict
    -p ProtectHome=yes -p PrivateTmp=yes -p PrivateNetwork=yes -p PrivateDevices=yes -p PrivateIPC=yes
    -p NoNewPrivileges=yes -p SystemCallFilter=@system-service -p SystemCallErrorNumber=EPERM
    -p SystemCallArchitectures=native -p UMask=0077 -p ProtectClock=yes -p ProtectHostname=yes
    -p ProtectKernelLogs=yes -p ProtectKernelTunables=yes -p ProtectKernelModules=yes
    -p ProtectControlGroups=yes -p RestrictAddressFamilies=AF_UNIX -p RestrictNamespaces=yes
    -p RestrictRealtime=yes -p RestrictSUIDSGID=yes -p LockPersonality=yes -p MemoryDenyWriteExecute=yes)

setup() {
    local u i py
    for u in ruyaspike-gd ruyaspike-door; do
        useradd --system --no-create-home --home-dir / --shell /usr/sbin/nologin "$u" || return 1
    done
    install -d -m 0700 -o ruyaspike-gd -g ruyaspike-gd "$root" "$coll"
    entry small; put small small.nes 65536
    entry big; fallocate -l 4G "$coll/big/big.bin" || return 1
    chown ruyaspike-gd:ruyaspike-gd "$coll/big/big.bin"; chmod 0644 "$coll/big/big.bin"
    entry set; put set game.cue 120; put set track01.bin 1048576; put set track02.bin 1048576
    entry m250; for i in $(seq 1 250); do put m250 "f$i.bin" 16; done
    entry m300; for i in $(seq 1 300); do put m300 "f$i.bin" 16; done
    entry wr; put wr wr.nes 4096 0666
    entry own; put own own.nes 4096 0644 "$user"
    install -d -m 0755 "$bin" && install -m 0644 "$here/vm-roms-probe.py" "$bin/" || return 1
    cat > "$conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="ruyaspike-gd"><allow own="$gd"/></policy>
  <policy user="ruyaspike-door">
    <allow own="$door"/>
    <allow send_destination="$gd" send_interface="$gd" send_member="OpenRom" send_type="method_call"/>
  </policy>
  <policy user="root"><allow send_destination="$gd"/></policy>
  <policy context="default">
    <allow send_destination="$door" send_interface="$door" send_member="OpenRom" send_type="method_call"/>
  </policy>
</busconfig>
EOF
    systemctl reload dbus-broker.service || return 1
    start_gd ro || return 1
    systemd-run --quiet --unit=ruyaspike-door -p Type=dbus -p BusName="$door" -p User=ruyaspike-door "${hard[@]}" \
        /usr/bin/python3 -I "$bin/vm-roms-probe.py" door "$coll" || return 1
    # The sandboxed client: a runtime with only sh and its libraries, python3 from the host through host-os.
    mkdir -p "$work/rt/files" "$work/rt/usr/bin" "$work/rt/usr/lib64" "$work/$app/files/bin" "$work/$app/files/share"
    cp /usr/bin/bash "$work/rt/usr/bin/sh" || return 1
    for i in $(ldd /usr/bin/bash | awk '/=> \//{print $3} /ld-linux/{print $1}' | sort -u); do cp "$i" "$work/rt/usr/lib64/"; done
    printf '[Runtime]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\n' "$rt" "$rt" "$rt" > "$work/rt/metadata"
    flatpak build-export --runtime "$work/repo" "$work/rt" stable >/dev/null 2>&1 || return 1
    py="$(readlink -f /usr/bin/python3)"
    cp "$here/vm-roms-probe.py" "$work/$app/files/share/"
    cat > "$work/$app/files/bin/probe" <<EOF
#!/bin/sh
export PYTHONHOME=/run/host/usr
exec /run/host/usr/lib64/ld-linux-x86-64.so.2 --library-path /run/host/usr/lib64 /run/host$py -I /app/share/vm-roms-probe.py "\$@"
EOF
    chmod 755 "$work/$app/files/bin/probe"
    printf '[Application]\nname=%s\nruntime=%s/x86_64/stable\nsdk=%s/x86_64/stable\ncommand=probe\n' "$app" "$rt" "$rt" > "$work/$app/metadata"
    flatpak build-finish --command=probe --system-talk-name="$door" --filesystem=host-os:ro "$work/$app" >/dev/null 2>&1 || return 1
    flatpak build-export "$work/repo" "$work/$app" stable >/dev/null 2>&1 || return 1
    flatpak remote-add --system --if-not-exists --no-gpg-verify "$remote" "file://$work/repo" >/dev/null 2>&1 || return 1
    flatpak install --system -y --noninteractive "$remote" "$rt" "$app" >"$work/install.log" 2>&1 || { tail -5 "$work/install.log"; return 1; }
}

# The probe inside the test app's sandbox, as the signed-in profile (its system bus is xdg-dbus-proxy).
sandbox() {
    systemd-run --machine="$user@.host" --user --wait --pipe --quiet --collect --no-ask-password \
        flatpak run --command=probe "$app" "$@" </dev/null 2>&1
}
as_user() { runuser -u "$1" -- /usr/bin/python3 -I "$bin/vm-roms-probe.py" "${@:2}" 2>&1; }
host() { /usr/bin/python3 -I "$bin/vm-roms-probe.py" "$@" 2>&1; }
# expect <label> <output> <line pattern>
expect() { if echo "$2" | grep -qE "$3"; then ok "$1"; else bad "$1: no line matching '$3'"; fi; }

check_facts() {
    local out want
    echo "--- fact 1: the fds in the sandbox"
    want="$(head -c 1048576 "$coll/small/small.nes" | sha256sum | cut -d' ' -f1)"
    out="$(sandbox facts "$door" small "$want")"; echo "$out" | sed 's/^/    /'
    expect "OpenRom small through xdg-dbus-proxy: ok, one fd" "$out" '^FACT call status=ok members=1 fds=1'
    expect "the fd is O_RDONLY" "$out" 'flags=O_RDONLY'
    expect "its bytes match the file" "$out" 'sha256\(first MiB\)=match'
    expect "write(fd) fails EBADF" "$out" '^FACT write\(fd\): EBADF'
    expect "a read-only reopen of /proc/self/fd/N works" "$out" '^FACT reopen O_RDONLY: ok'
    expect "a read-write reopen fails EACCES" "$out" '^FACT reopen O_RDWR: EACCES'
    expect "a write-only reopen fails EACCES" "$out" '^FACT reopen O_WRONLY\|O_APPEND: EACCES'
    expect "F_SETFL cannot change the access mode" "$out" 'then access mode: ok O_RDONLY'
    expect "ftruncate fails" "$out" '^FACT ftruncate: (EINVAL|EBADF)'
    expect "fchmod fails (EROFS on the ro mount)" "$out" '^FACT fchmod 0666: (EPERM|EROFS)'
    expect "a shared writable mmap fails EACCES" "$out" 'MAP_SHARED\|PROT_WRITE: EACCES'
    expect "openat(fd, ..) fails ENOTDIR" "$out" "^FACT openat\(fd, '..'\): ENOTDIR"
    expect "a hard link into the app's data fails" "$out" '^FACT link .*: (EPERM|EXDEV|ENOENT)'
    out="$(sandbox facts "$door" big)"; echo "$out" | grep -E 'call|member|pread' | sed 's/^/    /'
    expect "OpenRom big (4 GiB): ok, fstat says 4294967296" "$out" 'size=4294967296'
    expect "the big file's last page reads" "$out" 'pread at end-4096: ok 4096'
    out="$(sandbox facts "$door" set)"; echo "$out" | grep -E 'call|member' | sed 's/^/    /'
    expect "OpenRom set: three members, three fds" "$out" '^FACT call status=ok members=3 fds=3'
    out="$(sandbox facts "$door" m250)"; echo "$out" | grep -E '^FACT call' | sed 's/^/    /'
    expect "250 fds in one reply arrive" "$out" '^FACT call status=ok members=250 fds=250'
    out="$(sandbox facts "$door" m300)"; echo "$out" | grep -E '^FACT call' | sed 's/^/    /'
    expect "300 fds in one reply do not (SCM_MAX_FD 253)" "$out" '^FACT call (status=failed|org\.)'
    # The stand-in's collection is on a read-only mount (start_gd ro): the fd carries that mount, so a
    # reopen for writing is EROFS even for files whose mode would allow it.
    out="$(sandbox facts "$door" wr)"; echo "$out" | grep -E 'member|reopen' | sed 's/^/    /'
    expect "ro mount, a 0666 file: the read-write reopen fails EROFS" "$out" '^FACT reopen O_RDWR: EROFS'
    out="$(sandbox facts "$door" own)"; echo "$out" | grep -E 'member|reopen|fchmod' | sed 's/^/    /'
    expect "ro mount, a file the profile owns: the read-write reopen fails EROFS" "$out" '^FACT reopen O_RDWR: EROFS'
    echo "--- fact 1b: the same with the collection writable in the stand-in's namespace"
    start_gd rw || { bad "cannot restart the stand-in with ReadWritePaths"; return; }
    out="$(sandbox facts "$door" small)"; echo "$out" | grep -E 'member|reopen|fchmod' | sed 's/^/    /'
    expect "rw mount, 0644 file of another user: the read-write reopen still fails EACCES" "$out" '^FACT reopen O_RDWR: EACCES'
    expect "rw mount, 0644 file of another user: fchmod fails EPERM" "$out" '^FACT fchmod 0666: EPERM'
    out="$(sandbox facts "$door" wr)"; echo "$out" | grep -E 'member|reopen' | sed 's/^/    /'
    expect "rw mount, a 0666 file: the read-write reopen WORKS (the mode is the only guard)" "$out" '^FACT reopen O_RDWR: ok'
    out="$(sandbox facts "$door" own)"; echo "$out" | grep -E 'member|reopen|fchmod' | sed 's/^/    /'
    expect "rw mount, a file the profile owns: the read-write reopen WORKS" "$out" '^FACT reopen O_RDWR: ok'
    start_gd ro || bad "cannot restart the stand-in read-only"
}

check_paths() {
    local out
    echo "--- fact 2: no path to the collection"
    out="$(sandbox paths "$root" "$coll" "$coll/small" "$coll/small/small.nes" /var/lib /run/host/var/lib/ruyaspike-roms /run/host/root)"
    echo "$out" | sed 's/^/    /'
    if echo "$out" | grep '^PATH' | grep -qE 'stat=ok|list=ok|open=ok'; then
        echo "$out" | grep '^PATH /var/lib ' | grep -q 'list=ok' && ! echo "$out" | grep '^PATH /var/lib/ruyaspike\|^PATH /run/host/var' | grep -q '=ok' \
            && ok "the sandbox sees its own /var/lib only, not the collection" || bad "the sandbox reaches a collection path"
    else
        ok "the sandbox reaches none of the paths"
    fi
    out="$(as_user "$user" paths "$root" "$coll/small" "$coll/small/small.nes")"; echo "$out" | sed 's/^/    /'
    # The top directory's own stat works (its parent is 0755): the name is not secret, its contents are.
    echo "$out" | grep '^PATH' | grep -qE 'list=ok|open=ok' && bad "$user lists or opens the collection outside a sandbox" \
        || ok "$user (no sandbox) cannot list or open anything: the 0700 directory refuses"
    echo "$out" | grep "^PATH $coll/small " | grep -q 'stat=EACCES' && ok "$user cannot even stat an entry" || bad "$user stats an entry"
    out="$(journalctl -b -u ruyaspike-door.service -o cat --no-pager 2>&1 | grep 'door: stat' | tail -1)"; echo "    $out"
    expect "the door user cannot stat the collection" "$out" 'EACCES'
    out="$(as_user ruyaspike-door call "$gd" "$gd" Delete)"; echo "    door -> $gd.Delete: $out"
    expect "the door may call nothing of the stand-in but OpenRom" "$out" 'AccessDenied'
    out="$(sandbox call "$gd" "$gd" OpenRom)"; echo "    sandbox -> $gd: $out"
    expect "the sandbox cannot call the stand-in directly (proxy filter)" "$out" 'CALL org\.freedesktop\.DBus\.Error\.(ServiceUnknown|AccessDenied|NameHasNoOwner)'
}

check_bench() {
    local i
    echo "--- fact 3: cost per OpenRom (ms)"
    for id in __none__ small big set; do
        host bench "$gd" "$id" 200 | sed 's/^/    root -> stand-in: /'
        host bench "$door" "$id" 200 | sed 's/^/    root -> door -> stand-in: /'
        sandbox bench "$door" "$id" 200 | sed 's/^/    sandbox -> proxy -> door -> stand-in: /'
    done
    as_user "$user" bench "$door" small 200 | sed "s/^/    $user (no sandbox) -> door -> stand-in: /"
    echo "    cold, root -> door, caches dropped, 50 runs:"
    for i in $(seq 1 50); do echo 3 > /proc/sys/vm/drop_caches; host cold "$door" small; done | summarise
    echo "    cold, sandbox -> door, caches dropped, 50 runs (first call of a new app):"
    for i in $(seq 1 50); do echo 3 > /proc/sys/vm/drop_caches; sandbox cold "$door" small; done | summarise
    echo "    cold, sandbox -> door, 4 GiB file, caches dropped, 50 runs:"
    for i in $(seq 1 50); do echo 3 > /proc/sys/vm/drop_caches; sandbox cold "$door" big; done | summarise
    ok "bench printed"
}
summarise() {
    python3 -I -c '
import sys
c, t = [], []
for l in sys.stdin:
    if l.startswith("COLD"):
        f = dict(x.split("=") for x in l.split()[1:4])
        c.append(float(f["connect"])); t.append(float(f["call"]))
    else:
        print("    ?", l.rstrip())
for name, v in (("connect", c), ("call", t)):
    v.sort()
    if v:
        print(f"    {name}: n={len(v)} median={v[len(v)//2]:.3f} p95={v[max(0, round(0.95*len(v))-1)]:.3f} max={v[-1]:.3f}")
'
}

only_setup() {
    signed_in || exit 1
    clean
    setup && { ok "spike pieces set up (mode clean removes them)"; exit 0; }
    bad "setup failed"; clean; exit 1
}

case "$mode" in
clean) clean; echo "removed the spike pieces"; exit 0 ;;
setup) only_setup ;;
check|facts|paths|bench) ;;
*) echo "usage: $0 [check|facts|paths|bench|setup|clean]"; exit 2 ;;
esac
signed_in || exit 1
clean
setup && ok "spike pieces set up" || { bad "setup failed"; clean; exit 1; }
[ "$mode" = check ] || [ "$mode" = facts ] && check_facts
[ "$mode" = check ] || [ "$mode" = paths ] && check_paths
[ "$mode" = check ] || [ "$mode" = bench ] && check_bench
clean
[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
