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
- **Merged, not Done:**
  - RUY-430 (vm-input-check beside the shell's routing) and RUY-22 (GlassShadow in Loaders): their merge gate was running at handoff; check `output\merge-gate-22.log` and move RUY-430 to Done if it is green.
  - RUY-22 also waits for its Dell criteria (pills after display sleep, L0 VRAM; RUY-450).
- **In flight (builders in their own worktrees; this session's agents end with it):**
  - RUY-434 (image: patched satellite, Xwayland): `D:\dev\RuyaOS-worktrees\RUY-434`; it owns WSL and the VM for its image build.
  - RUY-435 (ruya-session X11 mode): `D:\dev\RuyaOS-worktrees\RUY-435`.
  - Look at each worktree's last commit and the ticket state. In Review means a reviewer; otherwise resume the work with a new builder on the same branch.
  - Then RUY-436 (vm-x11-check and baseline). Alien Arena on the Dell needs all three.
- **Images:**
  - 0.0.71: VM queue 11 PASS, 3 FAIL, all three check-script problems (fixed by RUY-430).
  - 0.0.72 (main 07d86bf): CHAIN OK; the Dell update was started at handoff, so check `output\dell-update-0.0.72.log`.
  - 0.0.72 has 07d86bf and RUY-422, but not RUY-430 or RUY-22.
  - Owed in the VM on 0.0.72: `vm-devices-check.sh bluetooth` (RUY-422) and the input checks with RUY-430's scripts.

## Owner decisions this session (recorded in specs and tickets)
1. ADR-017/027 amendment: a new pad asks "Who's playing?" on connect and pauses the game; one controller per profile (a new pad takes it over); every player signed in, PIN if set; several temporary guests, wiped on leave. RUY-121, 122, 38, 124 and 125 are back in Backlog; **RUY-448 (lead) replans them, design canvas first**.
2. ADR-024: the virtual pad matches the controller (virtual DualSense, Switch Pro, else Xbox 360; a per-game Xbox override). **RUY-449 (lead spike, Dell)**.
3. RUY-1 got high priority; the 2 h STK freeze test (RUY-425's last evidence) is **planned for later**. Script it as `dell-freeze-check.sh` (RUY-390 comment).
4. Owner question still open: may we offer the two satellite patches upstream (publishing)?

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
- Paper Plane issue **not filed** (the auto-mode classifier blocked `gh issue create`): a `move` to the current state with `evidence` says "Already there" and does not say whether the evidence was stored. The owner may file it or allow the call.

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or `python -c`: use Write/Edit. `pkill -f`/`pgrep -f` over SSH match the SSH command line itself: use a pid file.
- The Dell's `bootloader-update.service` fails on every boot: Secure Boot db lacks the Microsoft UEFI CA 2023 (harmless today; RUY-24).
- Paper Plane REST: `POST /api/tools/<tool>`; `PATCH /api/tickets/RUY-n {"sort_order": n}`.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-12 (lead-14) | 182d99f..b99ad4a | RUY-2, RUY-5 (lead); 401, 154, 411, 412, 3 | round 2+ for every ticket; joydev js leak found and closed | 1277 QML + 107 skips | 0.0.69-xpad OK |
| 2026-11-12 (lead-15) | 7a46c55..HEAD | RUY-1 (lead); 409, 410, 425, 421, 415, 422, 424, 430, 22 | round 2 for 409 (thaw test gap) and 410 (use-after-free); virtual-pad toast bug fixed by the lead; 0.0.71 input checks failing on script problems (RUY-430) | 1310 QML + 107 skips | 0.0.71 queue 11/14 (3 script fails); Dell 0.0.71 hw: 428, 409 route, 410, 427 PASS |
