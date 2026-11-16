#!/usr/bin/env bash
# Security posture of a booted image against image/security-baseline.json (T-424). Runs in the VM as
# root, like the other vm-*-check.sh (the lead's queue copies it to /root together with the baseline):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-security-check.sh image/security-baseline.json root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-security-check.sh [check|measure|signals]
# Steps (each prints PASS or FAIL lines; any FAIL makes the exit status 1):
#   units     every ruya-*.service in the image: systemd-analyze security exposure <= its baseline value
#   ports     listening TCP/UDP sockets (ss -H -tuln), as proto:scope:port (scope loopback or any, RUY-18),
#             equal the baseline set
#   selinux   getenforce is Enforcing; no ruya-* process in unconfined_service_t unless the baseline names it
#   files     setuid/setgid files under /usr equal the baseline; nothing under /usr or /etc is world-writable
#   accounts  only baseline accounts have a login shell or a usable password
#   x11       (RUY-436, ADR-034) no abstract @/tmp/.X11-unix listener; every X* socket is 0700 and owned by a profile
#             user (ruya-p<N>); every running Xwayland has -auth and -nolisten local and runs in a baseline domain
#   busrecv   (RUY-594) every /usr/share/dbus-1/system.d/org.ruyaos.*.conf denies receiving the service's signals in the
#             default context (a deny narrowed by receive_member/_interface/_path/_error/_requested_reply or eavesdrop closes nothing: RUY-616)
#             and allows them to root and ruya-shell only, with no receive deny in their policies (the policy as installed;
#             `signals` proves the bus keeps it)
# `signals` (RUY-594; not part of `check`: it stops the compositor for about 25 s and needs a pad-capable VM) runs
# `vm-input-check.sh signals` from this directory (copy it and vm-input-probe.py next to this script): plain bus clients as root
# and ruya-shell hear Input1's TestInput and UserActive while a pad is pressed; as nobody, a profile user, ruya-link and
# ruya-library they hear none (and do hear the bus's own NameOwnerChanged, so the silence is the policy's).
# `measure` prints a draft baseline of THIS system (to update the baseline file: review the diff, and give
# every looser value a "reason" in the same commit). A missing tool is a FAIL, never a SKIP.
# Host tests (scripts/test-vm-checks.sh) set SEC_* variables to point at fixtures and put fakes in PATH.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseline="${SEC_BASELINE:-}"
for c in "$here/security-baseline.json" "$here/../image/security-baseline.json" /root/security-baseline.json; do
    [ -n "$baseline" ] || { [ -f "$c" ] && baseline="$c"; }
done
usr="${SEC_USR:-/usr}"
etc="${SEC_ETC:-/etc}"
unitdirs="${SEC_UNITDIRS:-/usr/lib/systemd/system /etc/systemd/system}"
x11dir="${SEC_X11DIR:-/tmp/.X11-unix}"
passwd="${SEC_PASSWD:-/etc/passwd}"
shadow="${SEC_SHADOW:-/etc/shadow}"

buspolicy="${SEC_BUSPOLICY:-/usr/share/dbus-1/system.d}"

mode="${1:-check}"
case "$mode" in check|measure|signals) ;; *) echo "usage: $0 [check|measure|signals]"; exit 2 ;; esac

if [ "$mode" = signals ]; then
    # A missing script is a FAIL, never a skip.
    sigcheck="${SEC_INPUT_CHECK:-$here/vm-input-check.sh}"
    if [ ! -f "$sigcheck" ] || [ ! -f "$(dirname "$sigcheck")/vm-input-probe.py" ]; then
        echo "FAIL: signals: vm-input-check.sh and vm-input-probe.py must be next to this script (scp them to /root)"
        echo "SOME CHECKS FAILED"
        exit 1
    fi
    exec bash "$sigcheck" signals
fi

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

# --- gather facts into files; a tool that fails is a FAIL of its step (the step then reads an empty file)
: > "$t/units.txt"; : > "$t/gather-errors.txt"
names=""
for d in $unitdirs; do
    for f in "$d"/ruya-*.service; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        case " $names " in *" $b "*) ;; *) names="$names $b" ;; esac
    done
done
for u in $names; do
    case "$u" in *@.service) inst="${u%@.service}@check.service" ;; *) inst="$u" ;; esac
    out="$(systemd-analyze security --no-pager "$inst" 2>&1)"; rc=$?
    # "-> Overall exposure level for ruya-library.service: 1.0 OK" (the same text on every systemd we ship)
    exposure="$(printf '%s\n' "$out" | sed -n 's/.*Overall exposure level for [^:]*: \([0-9][0-9.]*\).*/\1/p' | tail -1)"
    if [ "$rc" != 0 ] || [ -z "$exposure" ]; then
        echo "systemd-analyze security $inst failed (exit $rc): $(printf '%s' "$out" | tail -1)" >> "$t/gather-errors.txt"
        echo "$u ERR" >> "$t/units.txt"
    else
        echo "$u $exposure" >> "$t/units.txt"
    fi
done

ss -H -tuln > "$t/ss.txt" 2> "$t/ss.err" || echo "ss -H -tuln failed: $(cat "$t/ss.err")" >> "$t/gather-errors.txt"
getenforce > "$t/getenforce.txt" 2>&1 || echo "getenforce failed: $(cat "$t/getenforce.txt")" >> "$t/gather-errors.txt"
ps -e -o label= -o comm= > "$t/ps.txt" 2> "$t/ps.err" || echo "ps failed: $(cat "$t/ps.err")" >> "$t/gather-errors.txt"
ss -H -xln > "$t/ssx.txt" 2> "$t/ssx.err" || echo "ss -H -xln failed: $(cat "$t/ssx.err")" >> "$t/gather-errors.txt"
# Xwayland processes with their SELinux label and arguments (X11 apps start one each, on demand).
ps -e -o pid= -o label= -o comm= -o args= > "$t/psx.txt" 2> "$t/psx.err" || echo "ps (Xwayland) failed: $(cat "$t/psx.err")" >> "$t/gather-errors.txt"
: > "$t/x11sockets.txt"
if [ -d "$x11dir" ]; then
    find "$x11dir" -maxdepth 1 -name 'X*' -printf '%m %u %y %p\n' > "$t/x11sockets.txt" 2> "$t/find3.err" || true
    [ -s "$t/find3.err" ] && echo "find X sockets: $(head -1 "$t/find3.err")" >> "$t/gather-errors.txt"
fi
find "$usr" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2> "$t/find1.err" | sort > "$t/setid.txt" \
    || true
[ -s "$t/find1.err" ] && echo "find setuid: $(head -1 "$t/find1.err")" >> "$t/gather-errors.txt"
find "$usr" "$etc" -xdev ! -type l -perm -0002 2> "$t/find2.err" | sort > "$t/ww.txt" || true
[ -s "$t/find2.err" ] && echo "find world-writable: $(head -1 "$t/find2.err")" >> "$t/gather-errors.txt"
mkdir "$t/bus"
cp "$buspolicy"/org.ruyaos.*.conf "$t/bus/" 2>/dev/null || echo "no org.ruyaos.*.conf in $buspolicy" >> "$t/gather-errors.txt"
cp "$passwd" "$t/passwd.txt" 2>> "$t/gather-errors.txt" || echo "cannot read $passwd" >> "$t/gather-errors.txt"
cp "$shadow" "$t/shadow.txt" 2>> "$t/gather-errors.txt" || echo "cannot read $shadow" >> "$t/gather-errors.txt"

python3 -I - "$mode" "$baseline" "$t" <<'PYEOF'
import json, os, re, sys

mode, baseline_path, t = sys.argv[1:4]

def read(name):
    with open(os.path.join(t, name), encoding="utf-8", errors="replace") as f:
        return f.read()

def lines(name):
    return [l for l in read(name).splitlines() if l.strip()]

failed = False
def ok(msg):
    print("PASS: " + msg)
def bad(msg):
    global failed
    failed = True
    print("FAIL: " + msg)

# ---- facts
units = {}
for l in lines("units.txt"):
    name, val = l.split()
    units[name] = None if val == "ERR" else float(val)

# RUY-18: a port is keyed proto:scope:port, so a listener that moves from loopback to every address fails.
# scope "loopback": 127.0.0.0/8, ::1 (also IPv4-mapped) or bound to the lo interface ("127.0.0.53%lo:53");
# scope "any": everything else, a wildcard (0.0.0.0, [::], *) or a network address: reachable from outside.
import ipaddress
def port_scope(addr):
    addr, _, iface = addr.partition("%")
    addr = addr.strip("[]")
    if iface == "lo":
        return "loopback"
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return "any"
    if getattr(ip, "ipv4_mapped", None):
        ip = ip.ipv4_mapped
    return "loopback" if ip.is_loopback else "any"
PORT_KEY = re.compile(r"(tcp|udp):(loopback|any):[0-9]+")
ports = set()
for l in lines("ss.txt"):
    f = l.split()
    if len(f) >= 5 and f[0] in ("tcp", "udp"):
        addr, _, port = f[4].rpartition(":")
        ports.add("%s:%s:%s" % (f[0], port_scope(addr), port))

enforce = read("getenforce.txt").strip()

unconfined = set()
for l in lines("ps.txt"):
    f = l.split()
    if len(f) >= 2 and f[1].startswith("ruya-") and ":unconfined_service_t:" in f[0]:
        unconfined.add(f[1])

setid = set(lines("setid.txt"))
worldw = lines("ww.txt")

LOCKED_SHELLS = ("nologin", "/bin/false", "/usr/bin/false", "/sbin/halt", "/bin/sync", "/sbin/shutdown", "/usr/sbin/halt", "/usr/sbin/shutdown", "/usr/bin/sync", "/bin/true", "/usr/bin/true")
passwd = {}
for l in lines("passwd.txt"):
    f = l.split(":")
    if len(f) >= 7:
        passwd[f[0]] = f[6]
shadow = {}
for l in lines("shadow.txt"):
    f = l.split(":")
    if len(f) >= 2:
        shadow[f[0]] = f[1]
accounts = set()
for name, shell in passwd.items():
    shell = shell.strip()
    login_shell = shell != "" and not any(shell.endswith(s) or shell == s for s in LOCKED_SHELLS)
    pw = shadow.get(name, "*")
    usable = not (pw.startswith("!") or pw.startswith("*"))   # an empty field is "no password needed": usable
    if login_shell or usable:
        accounts.add(name)

# X11 (RUY-436): listening unix sockets, the X* entries of the socket directory, Xwayland processes
abstract_x = []
for l in lines("ssx.txt"):
    f = l.split()
    if len(f) >= 5 and f[4].startswith("@/tmp/.X11-unix"):
        abstract_x.append(f[4])
x_entries = []     # (mode, owner, type, path)
for l in lines("x11sockets.txt"):
    f = l.split(None, 3)
    if len(f) == 4:
        x_entries.append(tuple(f))
xwayland = []      # (pid, selinux type, argument list)
for l in lines("psx.txt"):
    f = l.split(None, 3)
    if len(f) >= 3 and f[2] == "Xwayland":
        label = f[1].split(":")
        xwayland.append((f[0], label[2] if len(label) > 2 else f[1], f[3].split() if len(f) > 3 else []))

errors = lines("gather-errors.txt")

if mode == "measure":
    draft = {
        "units": {u: {"max_exposure": units[u]} for u in sorted(units) if units[u] is not None},
        "ports": [{"port": p, "reason": "TODO"} for p in sorted(ports)],
        "unconfined": [{"process": p, "reason": "TODO"} for p in sorted(unconfined)],
        "setid": [{"path": p, "reason": "TODO"} for p in sorted(setid)],
        "accounts": [{"name": a, "reason": "TODO"} for a in sorted(accounts)],
        "xwayland_domains": [{"domain": d, "reason": "TODO"} for d in sorted({x[1] for x in xwayland})],
    }
    print(json.dumps(draft, indent=2))
    for e in errors:
        print("# " + e, file=sys.stderr)
    sys.exit(0)

# ---- baseline
try:
    with open(baseline_path, encoding="utf-8") as f:
        base = json.load(f)
except Exception as e:
    print("FAIL: cannot read the baseline %s: %s" % (baseline_path, e))
    sys.exit(1)

def need_reasons(section, key):
    # An entry with no reason is an unexplained exception.
    missing = [e.get(key, "?") for e in base.get(section, []) if not str(e.get("reason", "")).strip()]
    if missing:
        bad("baseline %s entries without a reason: %s" % (section, ", ".join(map(str, missing))))

# units
for e in errors:
    bad("measuring: " + e)
bu = base.get("units", {})
if not units:
    bad("units: no ruya-*.service found in the image")
for u in sorted(units):
    key = u
    if key not in bu:
        bad("unit %s is not in the baseline (add it with its exposure)" % u)
    elif units[u] is None:
        bad("unit %s: systemd-analyze security gave no exposure" % u)
    else:
        limit = float(bu[key]["max_exposure"])
        if units[u] > limit:
            bad("unit %s: exposure %.1f is above the baseline %.1f" % (u, units[u], limit))
        else:
            ok("unit %s exposure %.1f (baseline %.1f)" % (u, units[u], limit))
for u in sorted(set(bu) - set(units)):
    bad("baseline lists %s but the image has no such unit (remove it from the baseline)" % u)

# ports
bp = {e["port"] for e in base.get("ports", [])}
need_reasons("ports", "port")
oldkeys = sorted(p for p in bp if not PORT_KEY.fullmatch(str(p)))
if oldkeys:
    bad("baseline ports not written as proto:scope:port (scope loopback or any): " + ", ".join(map(str, oldkeys)))
if ports == bp:
    ok("listening sockets equal the baseline: " + ", ".join(sorted(ports)) if ports else "no listening sockets, as the baseline")
else:
    if ports - bp:
        bad("unexpected listening sockets: " + ", ".join(sorted(ports - bp)))
    if bp - ports:
        bad("baseline sockets not listening: " + ", ".join(sorted(bp - ports)))

# selinux
if enforce == "Enforcing":
    ok("SELinux is Enforcing")
else:
    bad("SELinux is '%s', want Enforcing" % enforce)
# ps prints the kernel's comm, cut to 15 characters (ruya-notifications -> ruya-notificati).
bun = {e["process"][:15] for e in base.get("unconfined", [])}
need_reasons("unconfined", "process")
if unconfined - bun:
    bad("ruya-* processes in unconfined_service_t not in the baseline: " + ", ".join(sorted(unconfined - bun)))
else:
    ok("no unnamed unconfined_service_t ruya-* process (named: %d)" % len(unconfined))

# files
bs = {e["path"] for e in base.get("setid", [])}
need_reasons("setid", "path")
if setid == bs:
    ok("%d setuid/setgid files under /usr, as the baseline" % len(setid))
else:
    if setid - bs:
        bad("setuid/setgid files not in the baseline: " + ", ".join(sorted(setid - bs)))
    if bs - setid:
        bad("baseline setuid/setgid files that are gone (remove them): " + ", ".join(sorted(bs - setid)))
if worldw:
    bad("world-writable under /usr or /etc: " + ", ".join(worldw[:10]))
else:
    ok("nothing world-writable under /usr or /etc")

# accounts
ba = {e["name"] for e in base.get("accounts", [])}
need_reasons("accounts", "name")
if accounts == ba:
    ok("accounts with a login shell or password: " + ", ".join(sorted(accounts)))
else:
    if accounts - ba:
        bad("accounts with a login shell or usable password not in the baseline: " + ", ".join(sorted(accounts - ba)))
    if ba - accounts:
        bad("baseline accounts without login (remove them): " + ", ".join(sorted(ba - accounts)))

# x11 (ADR-034 point 5): the isolation of an app's X server, as a standing assertion
if abstract_x:
    bad("abstract X11 listener(s) (any sandbox with network could connect): " + ", ".join(sorted(abstract_x)))
else:
    ok("no abstract @/tmp/.X11-unix listener")
badx = [e for e in x_entries if e[0] != "700" or not re.fullmatch(r"ruya-p[0-9]+", e[1])]
for mode, owner, _kind, path in badx:
    bad("X socket %s is mode %s owned by %s, want 700 owned by a profile user (ruya-p<N>)" % (path, mode, owner))
if not badx:
    ok("%d X socket(s), each 0700 and owned by a profile user" % len(x_entries) if x_entries else "no X socket (X11 apps start one on demand)")
bd = {e["domain"] for e in base.get("xwayland_domains", [])}
need_reasons("xwayland_domains", "domain")
for pid, domain, argv in xwayland:
    pairs = list(zip(argv, argv[1:]))
    if "-auth" not in argv:
        bad("Xwayland %s runs without -auth (no cookie required)" % pid)
    elif ("-nolisten", "local") not in pairs:
        bad("Xwayland %s runs without -nolisten local (it would listen on an abstract socket)" % pid)
    else:
        ok("Xwayland %s has -auth and -nolisten local" % pid)
    if domain in bd:
        ok("Xwayland %s runs in %s (named in the baseline)" % (pid, domain))
    else:
        bad("Xwayland %s runs in SELinux domain %s, not in the baseline (%s)" % (pid, domain, ", ".join(sorted(bd)) or "none"))
if not xwayland:
    ok("no Xwayland is running (X11 apps start one on demand)")

# busrecv (RUY-594): a service's signals are broadcasts; the policy decides who receives them
import xml.etree.ElementTree as ET
bus_dir = os.path.join(t, "bus")
bus_files = sorted(os.listdir(bus_dir)) if os.path.isdir(bus_dir) else []
if not bus_files:
    bad("busrecv: no org.ruyaos.*.conf to check")
for fname in bus_files:
    try:
        root = ET.parse(os.path.join(bus_dir, fname)).getroot()
    except Exception as e:
        bad("busrecv: %s is not valid XML: %s" % (fname, e))
        continue
    names, recv_deny, recv_allow = set(), set(), {}
    for pol in root.iter("policy"):
        user, ctx = pol.get("user"), pol.get("context")
        for rule in pol:
            sender, rtype = rule.get("receive_sender"), rule.get("receive_type")
            if rule.tag == "allow":
                for a in ("own", "send_destination"):
                    if rule.get(a):
                        names.add(rule.get(a))
            if sender is None:
                continue
            narrowed = sorted(a for a in rule.attrib if (a.startswith("receive_") and a not in ("receive_sender", "receive_type")) or a == "eavesdrop")
            if rtype != "signal":
                bad("busrecv: %s: a receive rule for %s without receive_type=signal (%s)" % (fname, sender, rule.tag))
            elif rule.tag == "deny" and ctx == "default" and narrowed:
                bad("busrecv: %s: a narrowed receive deny does not close the default for %s (it also names %s)" % (fname, sender, ", ".join(narrowed)))
            elif rule.tag == "deny" and ctx == "default":
                recv_deny.add(sender)
            elif rule.tag == "allow" and user in ("root", "ruya-shell"):
                recv_allow.setdefault(sender, set()).add(user)
            else:
                bad("busrecv: %s: unexpected receive rule %s for %s in policy %s%s" % (
                    fname, rule.tag, sender, user or ctx,
                    " (it would cut the shell or root off from the service's signals)" if rule.tag == "deny" and user in ("root", "ruya-shell") else ""))
    if not names:
        bad("busrecv: %s names no bus name" % fname)
    for n in sorted(names):
        if n not in recv_deny:
            bad("busrecv: %s: no default-context deny receive_sender for %s (any client could receive its signals)" % (fname, n))
        elif recv_allow.get(n, set()) != {"root", "ruya-shell"}:
            bad("busrecv: %s: signals of %s are allowed to %s, want root and ruya-shell" % (fname, n, ", ".join(sorted(recv_allow.get(n, []))) or "nobody"))
        else:
            ok("busrecv: %s signals go to root and ruya-shell only" % n)

print("SOME CHECKS FAILED" if failed else "ALL CHECKS PASSED")
sys.exit(1 if failed else 0)
PYEOF
exit $?
