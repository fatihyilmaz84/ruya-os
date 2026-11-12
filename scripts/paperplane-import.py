"""Import RuyaOS open tasks into Paper Plane through its HTTP tool API.

usage: import_ruya.py BASE_URL TOKEN_FILE [--limit N]
Reads docs/STATUS.md + docs/STATUS-backlog.md (board order) and the task files.
"""
import json, re, sys, urllib.request, urllib.parse
from pathlib import Path

DOCS = Path(r"D:\dev\RuyaOS\docs")
BASE, TOKFILE = sys.argv[1].rstrip("/"), sys.argv[2]
LIMIT = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
TOKEN = Path(TOKFILE).read_text(encoding="utf-8").strip()

ROW = re.compile(r"^\| \[(T-\d+)\]\((tasks/[^)]+)\) \| (.*?) \| (todo|blocked|in-progress) \| (.*?) \|\s*$")


def call(tool, body):
    req = urllib.request.Request(f"{BASE}/api/tools/{tool}", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}: {e.read().decode('utf-8')}"


chk = call("summary", {"project": "RUY"})
if not re.search(r"RUY RuyaOS: 0 tickets", chk):
    print("Refusing to import: RUY is not empty.\n" + chk[:200]); sys.exit(1)

rows = []
for name in ("STATUS.md", "STATUS-backlog.md"):
    for line in (DOCS / name).read_text(encoding="utf-8").splitlines():
        m = ROW.match(line)
        if m:
            rows.append(m.groups())
if LIMIT:
    rows = rows[:LIMIT]
print(f"{len(rows)} open rows from the board")

tickets, deps = [], {}
for tid, path, title, status, _ in rows:
    text = (DOCS / path).read_text(encoding="utf-8")
    head = re.search(r"^Status: .*$", text, re.M).group(0)
    f = {k.strip(): v.strip() for k, v in (p.split(":", 1) for p in head.split(" · ") if ":" in p)}
    labels = [f"phase:{f['Phase']}"] if "Phase" in f else []
    for part in re.split(r"[,/]", re.sub(r"\(.*?\)", "", f.get("Area", ""))):
        if part.strip():
            labels.append("area:" + part.strip().split()[0].lower())
    for key, pre in (("Size", "size"), ("Owner", "owner"), ("Complexity", "complexity"), ("Developer surface", "surface")):
        if f.get(key):
            labels.append(f"{pre}:{f[key].split()[0]}")
    if "**[lead]**" in title and "owner:lead" not in labels:
        labels.append("owner:lead")
    labels = list(dict.fromkeys(labels))
    clean = re.sub(r"\*\*\[lead\]\*\*\s*", "", title).strip()
    body = text.split("\n", 1)[1].replace(head, "", 1).strip()  # drop H1 and Status line
    has_ac = bool(re.search(r"^## Acceptance criteria", body, re.M))
    lead = "owner:lead" in labels
    state = "Blocked" if status == "blocked" else ("Ready" if has_ac and not lead else "Backlog")
    deps[tid] = [d for d in re.findall(r"T-\d+", f.get("Depends", ""))]
    tickets.append({"title": f"{tid} {clean}", "description": body, "state": state,
                    "labels": labels, "key": tid})

COLORS = {"phase": "#60646C", "area": "#3B82F6", "size": "#9AA4BC", "owner": "#8B5CF6",
          "complexity": "#F59E0B", "surface": "#46A758"}
wanted = sorted({lb for t in tickets for lb in t["labels"]})
made = 0
for lb in wanted:
    req = urllib.request.Request(f"{BASE}/api/projects/RUY/labels",
                                 data=json.dumps({"name": lb, "color": COLORS[lb.split(":")[0]]}).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30).read(); made += 1
    except urllib.error.HTTPError as e:
        if e.code not in (400, 409):
            print("label", lb, e.code, e.read()[:200]); sys.exit(1)
print(f"labels: {made} created of {len(wanted)}")

ids = {}
for i in range(0, len(tickets), 15):
    chunk = tickets[i:i + 15]
    out = call("create", {"project": "RUY", "batch": chunk})
    refs = re.findall(r"^Created\.\s+(RUY-\d+)\b.*?\s(T-\d+)\s", out, re.M)
    if len(refs) != len(chunk):
        print("UNPARSED create output:\n", out[:1500]); sys.exit(1)
    ids.update({t: r for r, t in refs})
print(f"created {len(ids)}")

edges = [{"ref": ids[d], "blocks": [ids[t]]} for t, ds in deps.items() for d in ds if d in ids and t in ids]
for i in range(0, len(edges), 40):
    out = call("update", {"batch": edges[i:i + 40]})
    if "rejected" in out.lower() or "HTTP" in out[:5]:
        print(out[:800])
print(f"{len(edges)} blocks relations")
