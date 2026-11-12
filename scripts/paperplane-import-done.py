"""Import the finished RuyaOS tasks (Status: done) into Paper Plane as Done or Cancelled tickets.

usage: paperplane-import-done.py BASE_URL TOKEN_FILE [--limit N]
Run after paperplane-import.py. Skips any T-nnn that already has a ticket, so it can be re-run.
Task files are only read.
"""
import json, re, sys, urllib.request
from pathlib import Path

TASKS = Path(__file__).resolve().parent.parent / "docs" / "tasks"
BASE, TOKFILE = sys.argv[1].rstrip("/"), sys.argv[2]
LIMIT = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
TOKEN = Path(TOKFILE).read_text(encoding="utf-8").strip()
COLORS = {"phase": "#60646C", "area": "#3B82F6", "size": "#9AA4BC", "owner": "#8B5CF6",
          "complexity": "#F59E0B", "surface": "#46A758"}


def call(tool, body=None, query=""):
    req = urllib.request.Request(f"{BASE}/api/tools/{tool}{query}",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(req, timeout=120).read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}: {e.read().decode('utf-8')}"


have = set(re.findall(r"\s(T-\d+)\s", call("list", query="?project=RUY&limit=500")))
print(len(have), "T-ids already in RUY")

tickets = []
for f in sorted(TASKS.glob("T-*.md"), key=lambda p: int(re.match(r"T-(\d+)", p.name)[1])):
    text = f.read_text(encoding="utf-8")
    head = re.search(r"^Status: (.*)$", text, re.M)
    if not head or not head.group(1).startswith("done"):
        continue
    tid = re.match(r"(T-\d+)", f.name)[1]
    if tid in have:
        continue
    h1 = re.match(r"# T-\d+\s*[-—:]*\s*(.*)", text.splitlines()[0])
    title = (h1.group(1) if h1 else f.stem).strip()
    fields = {k.strip(): v.strip() for k, v in (p.split(":", 1) for p in head.group(0).split(" · ") if ":" in p)}
    labels = [f"phase:{fields['Phase']}"] if "Phase" in fields else []
    for part in re.split(r"[,/]", re.sub(r"\(.*?\)", "", fields.get("Area", ""))):
        if part.strip():
            labels.append("area:" + part.strip().split()[0].lower())
    for key, pre in (("Size", "size"), ("Owner", "owner"), ("Complexity", "complexity"), ("Developer surface", "surface")):
        if fields.get(key):
            labels.append(f"{pre}:{fields[key].split()[0]}")
    labels = list(dict.fromkeys(labels))
    body = text.split("\n", 1)[1].replace(head.group(0), "", 1).strip()
    outcome = re.search(r"^## Outcome\s*\n+\s*(.*)", text, re.M)
    dropped = bool(outcome and outcome.group(1).lower().lstrip("*_ ").startswith("dropped"))
    tickets.append({"title": f"{tid} {title}", "description": body, "state": "Cancelled" if dropped else "Done",
                    "labels": labels})
if LIMIT:
    tickets = tickets[:LIMIT]
print(len(tickets), "finished tasks to import;", sum(t["state"] == "Cancelled" for t in tickets), "dropped")

for lb in sorted({lb for t in tickets for lb in t["labels"]}):
    req = urllib.request.Request(f"{BASE}/api/projects/RUY/labels",
                                 data=json.dumps({"name": lb, "color": COLORS[lb.split(":")[0]]}).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30).read()
    except urllib.error.HTTPError as e:
        if e.code not in (400, 409):
            print("label", lb, e.code); sys.exit(1)

made = 0
for i in range(0, len(tickets), 10):
    chunk = tickets[i:i + 10]
    out = call("create", {"project": "RUY", "batch": chunk})
    n = len(re.findall(r"^Created\.", out, re.M))
    if n != len(chunk):
        print("create problem after", made, "tickets:\n", out[:1200]); sys.exit(1)
    made += n
print("created", made)
