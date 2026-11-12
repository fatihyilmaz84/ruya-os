"""One-off: move what only lived in docs/STATUS.md (Inbox, blockers, owner decisions, VM queue, Dell list)
into Paper Plane tickets when Paper Plane became the source of truth (owner, 2026-11-12, lead-12).
Usage: py -3.12 -I scripts/paperplane-migrate-status.py <base url> <token file> [--dry-run]
Reads docs/STATUS.md and docs/STATUS-parked.md as they stood; never prints the token."""
import json
import re
import sys
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE, TOKEN_FILE = sys.argv[1].rstrip("/"), sys.argv[2]
DRY = "--dry-run" in sys.argv
TOKEN = open(TOKEN_FILE, encoding="utf-8").read().strip()
status = open("docs/STATUS.md", encoding="utf-8").read()
parked = open("docs/STATUS-parked.md", encoding="utf-8").read()


def section(text, heading_prefix):
    m = re.search(r"^## " + re.escape(heading_prefix) + r".*?$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else ""


def call(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + TOKEN,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return "HTTP %d %s" % (e.code, e.read().decode("utf-8", "replace")[:200])


def short(s, n=90):
    s = re.sub(r"[`*]", "", s).strip()
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


tickets = []
# Inbox lines of lead-12 and the open ones before (one ticket each); the pilot line is done by this move.
inbox = section(status, "Inbox")
for line in inbox.splitlines():
    if not line.startswith("- ("):
        continue
    if "Paper Plane ticketing pilot" in line or "lead-9, second triage" in line:
        continue
    m = re.match(r"- \(([^)]*)\) (.*)", line)
    src, what = m.group(1), m.group(2)
    if "Untriaged follow-ups" in what:
        which = "lead-11" if src.startswith("lead-11") else "lead-10"
        body = section(parked, "Inbox lines %s (untriaged)" % which)
        tickets.append({"title": "Inbox triage: %s's untriaged follow-ups" % which,
                        "description": "Plan these at the next planning pass (from STATUS-parked.md, verbatim):\n\n" + body + "\n",
                        "labels": ["inbox"], "state": "Backlog"})
        continue
    tickets.append({"title": "Inbox: " + short(what), "description": "(%s) %s\n" % (src, what),
                    "labels": ["inbox"], "state": "Backlog"})

# Blockers (B-nnn): Blocked tickets.
for row in re.findall(r"^\| (B-\d+) \| (.*?) \| (.*?) \| (.*?) \|$", section(status, "Blocked"), re.M):
    bid, what, needs, notes = row
    tickets.append({"title": "%s %s" % (bid, short(what, 80)),
                    "description": "%s\n\nNeeds: %s\n\n%s\n" % (what, needs, notes),
                    "labels": ["blocker"], "state": "Blocked"})

# Open owner decisions: one ticket each; the long form is attached to every one (it is short).
long_form = section(parked, "Open owner decisions before the 2026-11-11 trim")
for line in section(status, "Open owner decisions").splitlines():
    if not line.startswith("- "):
        continue
    title = re.sub(r"\*\*", "", line[2:]).split(":")[0]
    tickets.append({"title": "Owner decision: " + short(title, 80),
                    "description": line[2:] + "\n\nLong form of the open decisions (lead-11, verbatim):\n\n" + long_form + "\n",
                    "labels": ["owner-decision"], "state": "Backlog"})

# VM queue leftovers and the Dell look-at list.
tickets.append({"title": "VM queue: checks left after 0.0.67",
                "description": "Left after the 0.0.66 and 0.0.67 queues (lead-12): `vm-app-check.sh recreate` (T-464; needs a game frozen by hand), `vm-app-check.sh flow` by hand, `subset-icons.sh` (T-297), the sample re-run, the greenboot drill. The default list is in `scripts/vm-queue.ps1`.\n\nThe queue paragraph as it stood in STATUS.md:\n\n" + re.search(r"^\*\*VM queue\*\*.*$", status, re.M).group(0) + "\n",
                "labels": ["vm-queue"], "state": "Backlog"})
tickets.append({"title": "Dell look-at list (the next Dell pass)",
                "description": re.search(r"^\*\*Dell look-at list:\*\*.*$", status, re.M).group(0) + "\n\nThe list (STATUS-parked.md, verbatim):\n\n" + section(parked, "Dell look-at list (moved 2026-11-10, lead-8)") + "\n",
                "labels": ["dell"], "state": "Backlog"})

print("%d tickets" % len(tickets))
for t in tickets:
    print("  [%s] %s" % (t["state"], t["title"]))
if DRY:
    sys.exit(0)
colors = {"inbox": "#E5484D", "blocker": "#E54D2E", "owner-decision": "#8B5CF6", "vm-queue": "#0090FF", "dell": "#12A594"}
for name, color in colors.items():
    print("label", name, call("/api/projects/RUY/labels", {"name": name, "color": color})[:60])
for t in tickets:
    t["project"] = "RUY"
    print(call("/api/tools/create", t).splitlines()[0][:110])
