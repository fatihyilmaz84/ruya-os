# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. This file is the lead's session record.

## State at the end of lead-15 (Opus, 2026-11-12)

- **Review range:** 7a46c55..HEAD (this commit). Paper Plane `changes` cursor at the start was 1024.
- **Merged and Done:**
  - RUY-409: the shell drives Input1's route.
  - RUY-410: the emergency pad reader.
  - RUY-425: the per-profile pulse servers' `pulse.idle.timeout = 5`. Root cause: pipewire-pulse kept pulling a frozen OpenAL stream; libpulse aborts at about 2 GB of catch-up.
  - RUY-421 and RUY-415: flaky tests; the Linux loop ran 30/30.
  - RUY-422 and RUY-424: the service is the keyboard bond gate.
  - RUY-428 and RUY-427: Dell checks.
  - RUY-1 (lead spike): XWayland through `xwayland-satellite`, one per app instance; ADR-034 updated; build tickets RUY-434..437.
  - Lead fix 07d86bf: ruya-devices no longer treats `ruya-input/` virtual pads as connected controllers. The owner saw "Xbox 360 controller connected" toasts on every game launch and Hub close.
- Also Done: RUY-430, RUY-22 and RUY-435 (their VM and Dell checks are queued on RUY-390).
- **Overnight (2026-11-13, owner asleep; no image builds), all merged and Done:**
  - RUY-434: the image builds a patched xwayland-satellite. Its Outcome has a ready-to-paste upstream PR; file it (the owner approved).
  - RUY-436: vm-x11-check.sh and the X11 security baseline.
  - RUY-459: not a regression. Idle VMs went dark, then suspended, and WHPX cannot resume them. Test VMs now never suspend (credential), and vm-goto wakes a dark screen.
  - RUY-406: game settings format v1, its loader and a mock game. The API review added the invisible-text rule and a Versions section.
  - RUY-39: Settings > Controllers, capabilities and the button test.
- **Next:** an image with RUY-434 and RUY-435 for the VM (`vm-x11-check.sh`, `vm-input-check.sh caps`) and the Dell (Alien Arena, AAAAXY, Controllers). Then RUY-42 (the mapping UI, unblocked by RUY-39), RUY-40 and RUY-407 (needs a design canvas first, LEAD.md §5). Lead work: RUY-448, RUY-449, RUY-458.
- **Nothing is in flight**; no worktrees left.
- **lead-16 was proposed as a card** (the app starts sessions only from the owner's own message, not from an automated turn). The owner starts it with a click.
- **Images:**
  - 0.0.71: VM queue 11 PASS, 3 FAIL, all three check-script problems (fixed by RUY-430).
  - **The Dell runs 0.0.72** (main 07d86bf: the virtual-pad toast fix and RUY-422; rollback 0.0.71). The owner is asked to confirm that the toasts are gone.
  - Owed in the VM: `vm-devices-check.sh bluetooth` (RUY-422) and the input checks with RUY-430's scripts.
- **The owner works in this checkout too** (they committed ADR-018 Epic and RUY-452..456 during lead-15). Check `git status` before every lead commit.
- RUY-458 (inbox, lead): Library art from Flatpak metadata (icon, first screenshot as hero, brand colours). The owner asked; plan it.

## Owner decisions this session (recorded in specs and tickets)
1. ADR-017/027 amendment: a new pad asks "Who's playing?" on connect and pauses the game; one controller per profile (a new pad takes it over); every player signed in, PIN if set; several temporary guests, wiped on leave. RUY-121, 122, 38, 124 and 125 are back in Backlog; **RUY-448 (lead) replans them, design canvas first**.
2. ADR-024: the virtual pad matches the controller (virtual DualSense, Switch Pro, else Xbox 360; a per-game Xbox override). **RUY-449 (lead spike, Dell)**.
3. RUY-1 got high priority; the 2 h STK freeze test (RUY-425's last evidence) is **planned for later**. Script it as `dell-freeze-check.sh` (RUY-390 comment).
4. The owner said yes (2026-11-13) to offering the two satellite patches upstream, after RUY-434's VM check; the lead files the PR (RUY-434 comment).

## Next, in this order
1. Finish RUY-434 and RUY-435 (review, merge, image), then RUY-436, then Alien Arena and AAAAXY on the Dell (RUY-435 hw).
2. RUY-39 (Settings > Controllers), then RUY-42 (the "Controls in games" mapping UI, canvas done). The owner asked about mapping.
3. Lead work: RUY-448 (co-op replan, canvas) and RUY-449 (virtual DualSense spike).
4. Dell checks once an image has RUY-22: RUY-450; RUY-409's real-pad race needs the owner at the controller.

## Concerns (ranked)
1. Reviewers and builders touching the main checkout by relative paths: a reviewer mutated main's bluetooth.rs once (caught, reverted, the image was not affected). Tell agents "absolute paths in the worktree only".
2. The Dell is often in use by the owner: inputs appeared mid-check. Ask before long Dell runs.
3. The 98-guard and Fedora updates now carry two patched builds (qt-dmabuf, satellite): a failing patch stops the image build (intended).

## Process changes in lead-15
- Inbox rule: lead-made inbox tickets need `## Acceptance criteria` before Ready (Paper Plane enforces it).
- Paper Plane is now 0.11.0: `update` takes `sort_order` (#7 fixed), `summary` caps its lists and has `list has_blocker=true` (#8), and a call with an unknown argument is refused. Filed in lead-15 with the owner's permission: #9 (a same-state `move` with evidence says only "Already there") and #10 (`update blocks=[]` does not remove block relations; override the claim or move meanwhile).

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or `python -c`: use Write/Edit. `pkill -f`/`pgrep -f` over SSH match the SSH command line itself: use a pid file.
- The Dell's `bootloader-update.service` fails on every boot: Secure Boot db lacks the Microsoft UEFI CA 2023 (harmless today; RUY-24).
- Paper Plane REST: `POST /api/tools/<tool>`; ordering with `update sort_order=` (0.10+).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-12 (lead-14) | 182d99f..b99ad4a | RUY-2, RUY-5 (lead); 401, 154, 411, 412, 3 | round 2+ for every ticket; joydev js leak found and closed | 1277 QML + 107 skips | 0.0.69-xpad OK |
| 2026-11-12/13 (lead-15) | 7a46c55..HEAD | RUY-1 (lead); 409, 410, 425, 421, 415, 422, 424, 430, 22, 435, 434, 436, 459, 406, 39 | round 2 for 409 (thaw test gap) and 410 (use-after-free); virtual-pad toast bug fixed by the lead; 0.0.71 input checks failing on script problems (RUY-430) | 1310 QML + 107 skips | 0.0.71 queue 11/14 (3 script fails); Dell 0.0.71 hw: 428, 409 route, 410, 427 PASS |
