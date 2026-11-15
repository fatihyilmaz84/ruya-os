# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`, server 0.15.1 since 2026-11-15); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-22 (Opus, 2026-11-15)

- **Review range:** ab995891..HEAD. Paper Plane `changes`: read the latest 200.
- **Merged and Done (13):** 124, 405, 49, 483, 664, 674, 48, 662, 638, 511, 679, 680, 681; 650 cancelled (not reproducible). CI's Linux job (push-main) caught two Linux-only reds after the merges: the PIN pad's Turkish OK overflowed (floor now typeCaption) and an Activity test race (`t/lead22-linux-ci`). Lead fixes: slim removes sudo despite dnf's protection (`ad806ac5`, the 0.0.84 build failed on it), vm-queue summary keeps every FAIL (`7abef208`), a QML race in tst_whos_playing (`6d857db4`), the obsolete "Cancel" translation (`f2bc4d60`), shell/CLAUDE.md pruned to 8 KB.
- **Inbox triaged:** all 87 tickets (27 Ready, 33 Backlog, 17 lead decisions recorded as comments, 10 cancelled/merged). The lead decisions still need their builder tickets written: 468, 470, 476, 482, 487, 498, 500, 506, 508, 516, 519, 543, 613, 635, 639 (`list q=` "Lead decision (lead-22").
- **Image 0.0.84** (from ad806ac5: RUY-18 hardening, RUY-124/405 not in it): VM queue 30 checks; every failure was a check bug (fixed in RUY-679). **The Dell runs 0.0.84** (rollback 0.0.83; only bootloader-update.service failed, RUY-447). RUY-646 measured (exposure lower, LLMNR off, no sudo).
- **Paper Plane usage:** plugin `paperplane@paperplane` 0.15.1 installed (user scope); RuyaOS `settings.local.json` holds only `env` (URL + the hooks token), its old hooks removed; backups in `~/.claude/`. The `claude.exe` in `~/.local/bin` (Oct 2025) crashes on `OTEL_METRICS_EXPORTER=none` (issue EnigmaNL/PaperPlane#13): use the desktop's `%APPDATA%\Claude\claude-code\<ver>\...\claude.exe`.

## First thing next session
1. **RUY-681 (owner report: STK split-screen) is merged** but unproven on Linux: forwarding to pad2 already worked; the fix keeps every seated pad from `app` to the game's end (quiet, not destroyed, past the 60 s hold), ACLs pad1 first also in the udev fallback. Follow-up RUY-686 (pads at the launch, not at focus).
2. **Next image (0.0.85) and VM queue:** run `vm-boot-check.sh watchdog` FIRST in its boot (RUY-483), then the RUY-679 order (`session check`, `store`, `input twopads`, `session display`), then `input players` (RUY-124 owner), `profiles guests` (RUY-664), and RUY-681's `input coop`, `seathold`, `twopads`. Then `dell-update.sh`, `dell-hub-check.sh` (RUY-405), and STK co-op with the owner.
3. RUY-685 (high): Manage profiles blocks rename/delete of a guest-role profile (the owner's tyx).

## Owner decisions open
- RUY-632 (Guide on players 2-4; "Use this controller"), RUY-633 (age limit of all seated players: refuse the join?), RUY-673 (DualShock 3 over Bluetooth: a Dell spike first).

## Concerns (ranked)
1. Co-op on real hardware is still unproven (RUY-681); the owner found it on the Dell, not us.
2. Four lanes of `shots` collide (activation losses, 12-min mutex waits; RUY-682). RUY-511's `shots <file>` filter and retry are merged: use the filter.
3. merge-gate's RED summary hides the failing step (a translation lint showed as nothing): run `dev.ps1 test *> file` and grep its last lines (UTF-16: `iconv -f UTF-16`).

## Process changes in lead-22
- Inbox triage by one Opus planner into a JSON plan, applied by a script over `POST /api/tools/update` (scratchpad `apply_plan.py`); lead decisions recorded as comments, not tickets.
- VM failures go to a debug agent allowed to boot the VM / SSH the Dell (found 4 check bugs and 2 owner bugs in about 20 min each).
- vm-queue.ps1: the summary keeps every FAIL line (a 30-check queue hid 16 results).
- Merges wait while `image-chain.sh` reads `shell/` or `services/` (it builds from the checkout): grep `COPY shell|COPY services` in build.log before merging such a branch; never run a gate during `make-disk`.
- Remove a worktree only after its gate (it holds the builder's green marker).
- Paper Plane: issue #13 filed.

## Host facts learned
- dnf protects sudo itself (`/etc/dnf/protected.d/sudo.conf`, dnf5 `protect-sudo.conf`).
- Git Bash rewrites `/mnt/c/...` for `wsl`: prefix `MSYS_NO_PATHCONV=1`.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-15 (lead-21) | 00bbe87..ab99589 | 38 merged + 448 re-plan | rounds 2-3 for 11 tickets; ~45 filed | 1832 QML + 149 skips | 0.0.83 queue; Dell on 0.0.83 |
| 2026-11-15 (lead-22) | ab99589..HEAD | 13 merged, 87 inbox triaged | rounds 2 for 405, 49, 48, 662, 511, 679; lead fixes in 124, 48, 49, 638, 662; 1 image bug, 4 VM-check bugs, 2 owner bugs fixed (680, 681); 2 Linux-only reds fixed; ~20 filed | 1884 QML + 152 skips | 0.0.84 built (after a slim fix); queue failures all check bugs (patched checks passed in the VM, RUY-679); Dell on 0.0.84 |
