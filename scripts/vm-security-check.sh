#!/usr/bin/env bash
# Security posture of a booted image against image/security-baseline.json (T-424). Runs in the VM as
# root, like the other vm-*-check.sh (the lead's queue copies it to /root together with the baseline):
#   scp -i ~/.ssh/ruyaos_dev -P 2222 scripts/vm-security-check.sh image/security-baseline.json root@127.0.0.1:/root/
#   ssh -i ~/.ssh/ruyaos_dev -p 2222 root@127.0.0.1 bash /root/vm-security-check.sh [check|measure]
# Steps (each prints PASS or FAIL lines; any FAIL makes the exit status 1):
#   units     every ruya-*.service in the image: systemd-analyze security exposure <= its baseline value
#   ports     listening TCP/UDP sockets (ss -H -tuln), as proto:port, equal the baseline set
#   selinux   getenforce is Enforcing; no ruya-* process in unconfined_service_t unless the baseline names it
#   files     setuid/setgid files under /usr equal the baseline; nothing under /usr or /etc is world-writable
#   accounts  only baseline accounts have a login shell or a usable password
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
passwd="${SEC_PASSWD:-/etc/passwd}"
shadow="${SEC_SHADOW:-/etc/shadow}"

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
find "$usr" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2> "$t/find1.err" | sort > "$t/setid.txt" \
    || true
[ -s "$t/find1.err" ] && echo "find setuid: $(head -1 "$t/find1.err")" >> "$t/gather-errors.txt"
find "$usr" "$etc" -xdev ! -type l -perm -0002 2> "$t/find2.err" | sort > "$t/ww.txt" || true
[ -s "$t/find2.err" ] && echo "find world-writable: $(head -1 "$t/find2.err")" >> "$t/gather-errors.txt"
cp "$passwd" "$t/passwd.txt" 2>> "$t/gather-errors.txt" || echo "cannot read $passwd" >> "$t/gather-errors.txt"
cp "$shadow" "$t/shadow.txt" 2>> "$t/gather-errors.txt" || echo "cannot read $shadow" >> "$t/gather-errors.txt"

mode="${1:-check}"
case "$mode" in check|measure) ;; *) echo "usage: $0 [check|measure]"; exit 2 ;; esac

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

ports = set()
for l in lines("ss.txt"):
    f = l.split()
    if len(f) >= 5 and f[0] in ("tcp", "udp"):
        ports.add(f[0] + ":" + f[4].rsplit(":", 1)[-1])

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

errors = lines("gather-errors.txt")

if mode == "measure":
    draft = {
        "units": {u: {"max_exposure": units[u]} for u in sorted(units) if units[u] is not None},
        "ports": [{"port": p, "reason": "TODO"} for p in sorted(ports)],
        "unconfined": [{"process": p, "reason": "TODO"} for p in sorted(unconfined)],
        "setid": [{"path": p, "reason": "TODO"} for p in sorted(setid)],
        "accounts": [{"name": a, "reason": "TODO"} for a in sorted(accounts)],
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
bun = {e["process"] for e in base.get("unconfined", [])}
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

print("SOME CHECKS FAILED" if failed else "ALL CHECKS PASSED")
sys.exit(1 if failed else 0)
PYEOF
exit $?
