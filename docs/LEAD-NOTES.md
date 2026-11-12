# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`, **0.8.0 since 2026-11-12**); `docs/STATUS*.md` and `docs/tasks/T-*.md` are a frozen archive. This file is the lead's session record.

## State at the end of lead-14 (Opus, 2026-11-12; owner: "full blast", Ruya Input first)

- **Review range:** 182d99f..8be2889 (pushed; CI was green at 3ad160d, later runs not checked). The Dell still runs 0.0.68; the builder image 0.0.69-xpad was built only in WSL (not the Dell).
- **Merged and Done:**
  - RUY-401: Hub at large UI sizes. Lead decision: it may scroll at 150 % and above (02 §1.6).
  - RUY-154: Xbox 360 receiver. **The image had no `xpad` at all**; it now comes through `kernel-modules-extra`, ~3 MB, and `image-chain.sh` runs `check-image-input-drivers.sh`.
  - RUY-411: Bluetooth pairing hardening. Keyboards pair only from Settings > Bluetooth; the neutral `customDestructive: false` confirm.
  - RUY-412: Toasts v2. 4 rounds; its merge gate first went red on RUY-154's test, fixed in 8be2889.
- **Owner reported a SuperTuxKart crash on the Dell:** an abort in libpulse 11 s after a 1 h 53 min Hub freeze and the park-audio restore. Filed as **RUY-425** (high, `dell`), with the diagnosis.
- **Lead work, Done:** RUY-2 (Ruya Input spike on the Dell, engine decision: grow `ruya-inputd`, not InputPlumber; `docs/specs/06-input.md`, `schemas/input-profile-v1.json` with a test, draft `api/dbus/org.ruyaos.Input1.xml`, ADR-003/024 amended) and RUY-5 (ADR-027 written into 06 §11, 02 §4.2-4.3, 04 §3.7).
- **In flight (worktrees under `D:\dev\RuyaOS-worktrees\`):**
  - **RUY-3** (input service half, Opus builder, ~335k tokens in round 1; it was waiting for WSL to finish compacting before its "VM (this task)" image build). Told mid-build: `SetRoute` gains `app_id`; the virtual-pad udev rule must be pad-specific (`ruya-input/pad*`) because virtual keyboards and mice keep uaccess (06 §3).
  - **Design session** "Design the controller screens in Claude Design" (started by the owner): the RuyaOS design system plus RUY-39 / RUY-42 / RUY-38 numbers as ticket comments. Read its result before dispatching those tickets.
- **Planning done this session:** input chain re-checked and wired in Paper Plane: RUY-3 → RUY-409 (shell route) / RUY-410 (emergency reader) → RUY-42 → RUY-45 (split: 416 layers, 417 shortcuts) → RUY-46; RUY-43; RUY-47 split (418 actions, 419 haptics, 47 rebinding); RUY-411 and RUY-422 (Bluetooth). Owner's Claude Design request filed as RUY-412 (Toasts v2), RUY-413 and RUY-414 (notification centre, split by the lead), comment on RUY-88. Inbox: RUY-415, 420, 421, 423.

## Next, in this order
1. **RUY-3:** look at `D:\dev\RuyaOS-worktrees\RUY-3` (last seen at 9706215). If the builder's HANDOFF never arrived, dispatch `ruya-reviewer` (Opus, complexity hard) with "verify everything yourself". A UI-free diff needs no design or UX review; it needs `ruya-api-reviewer` (surface public-API).
2. The VM queue (RUY-390): `vm-input-check.sh` (RUY-3), `vm-devices-check.sh bluetooth` (RUY-411), and the drivers step of the next image chain (RUY-154). Then RUY-409 and RUY-410, the first Dell proof: SuperTuxKart races with the DualSense.
2b. RUY-425 (the STK crash) is the top `dell` bug, and a good second lane next to the input chain.
3. **Design first** (new owner rule, LEAD.md §5): the proposed session "Design the controller screens in Claude Design" (design system from 04 + `Theme.qml`, then RUY-39, RUY-42, RUY-38) should run before those builders start.
4. RUY-421 (tst_appflow flaky on Linux CI) is high priority: CI now prints Actual/Expected/Loc.
5. Usage attribution works for MCP-using agents: 3 tickets attributed (was 1). The lead session's own tokens stay unattributed (383.4M of 392.4M).
6. RUY-413 (notification centre, part 1) is unblocked by RUY-412.

## Concerns (ranked)
1. RUY-3 is large (hard, image + service); watch the 500k two-round budget.
2. CI flakes: tst_appflow (Linux CI), tst_perf_overlay GPU shot (RUY-423), tst_hub_controllers (RUY-415).
3. Builders over-report evidence (RUY-412 "read" shots that showed the wrong step; RUY-154 claimed xpad present without an image check). Reviewers caught both.
4. The board: 121 Ready, most blocked; `next` is the plan.

## Process changes in lead-14
- **Design first in Claude Design** for every new screen, flow, modal, panel or component (owner; LEAD.md §5, PLANNING.md quality bar).
- Builder and reviewer agents list their `mcp__paperplane-<role>__*` tools, so usage reaches tickets (was 283.5M unattributed).
- `run-qml-tests.sh` prints Actual/Expected/Loc of a failure (CI keeps no logs).
- `image-chain.sh` runs the pad driver check after every build.
- Not done: GitHub issues on Paper Plane (the permission check refused `gh issue create`): (1) `update` has no `sort_order`; (2) `summary`'s Blocked list is uncapped. File them when allowed.

## Host facts learned
- Never put backslashes in a Bash heredoc, `sed` or `python -c`: use Write/Edit. `pkill -f`/`pgrep -f` over SSH match the SSH command line itself: use a pid file.
- logind's `uaccess` builtin flushes foreign ACL entries on every udev event of a tagged node (06 §1).
- WSL "Compacting" (free-space.ps1) blocks every `wsl` call for minutes (`E_ILLEGAL_STATE_CHANGE`).
- Paper Plane REST: `POST /api/tools/<tool>`; `PATCH /api/tickets/RUY-n {"sort_order": n}`.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-12 (lead-13) | cbf4a4e..f7bf080 (docs only) | none (planning only) | inbox 22 → 0 | not run | none |
| 2026-11-12 (lead-14) | 182d99f..8be2889 | RUY-2, RUY-5 (lead); RUY-401, RUY-154, RUY-411, RUY-412 merged; RUY-3 in flight | round 2+ for every ticket (401 tie, 154 no xpad in image, 412 TR cut-off and shots, 411 window and red confirm, RUY-2 passthrough leak); one merge gate red (semantic conflict 154/412, fixed); rustix RUSTSEC fix; STK crash diagnosed (RUY-425) | 1277 QML + 107 skips | builder image 0.0.69-xpad RUYA_BOOT_OK; Dell spike on 0.0.68 |
