# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-27 "lead review 2f2f1e1..f7574e9"** (`git log --grep="lead review 2f2f1e1"`). Everything up to T-129 is reviewed.
- Next review: `git log --oneline <that commit>..HEAD`. Due after 3 builder tasks (the board says so).
- Last VM verification: lead image `0.0.11-lead` (2026-10-24). **No VM since: the WSL disk is broken (owner decision open in STATUS).**

## Concerns (ranked)

0. **WSL disk (owner).** Blocks T-130, T-132, T-133, T-134 and the T-131 VM check. Ask first each session. Until fixed, the board is host-only work: T-138, T-139, T-112, T-135, T-136, T-137, T-111, T-113 (8 tasks).
1. **T-130 `[lead]` is the critical path** (compositor session replaces cage). Phase 1's exit "overlay over a running app" and everything with apps wait on it. Do it as the lead task as soon as the VM works. Right after it write the **VM tasks that are reserved but not yet written** (they need the VM to be specified well):
   - `ruya-session` in the image: unit, polkit/policy, per-profile Wayland and PipeWire sockets (ADR-004/010), the real spawner, `ambient`/`media` levels; Store "Open" and tile launch; overlay switch/close app (after T-138/T-139);
   - `ruya-update` service over `bootc` (contract T-135), including showing greenboot's rollback event;
   - the BlueZ part of `ruya-devices` (contract T-136) and udisks2 (contract T-137).
   Every contract-and-mock task built meanwhile has a real service waiting; check the mocks against the services when those land (drift).
2. **Mock-only surface is growing:** Network, Store, and soon Update, Bluetooth, Storage and Session are unverified over D-Bus. Don't let more than about 4 contracts wait for the VM; if the disk stays broken, stop adding contract tasks and tell the owner the real bottleneck is hardware, not backlog.
3. **`ruya-store` job-signal race** (noted for T-134): `DBusStoreBackend::startJob` records the job id when the reply is handled, so a `JobFinished` dispatched before the reply watcher fires is dropped. Check against the real service; buffer unknown-job signals if seen.
4. **`ruya-devices` growth.** T-133 removes the 1 s `pw-dump` poll; T-132 adds NetworkManager to the same binary and a polkit rule. Check the rule is narrow and the hardening score stays "OK".
5. **Admin authorization is shell-side only** (PIN checked by the shell, bus policy restricts callers). T-135 asks its builder to write down whether the services should verify it; decide in the next review (security invariant territory).
6. **`shots` focus flakes:** T-127's guard works; if `TEST WINDOW LOST ACTIVATION` becomes frequent, look at what the desktop does, not the tests.
7. **CI** unchecked since T-122 and 6+ commits unpushed (owner decision). The first run will exercise the new `board lint`, the text/translation lints and the new crate.
8. **Real hardware (B-002), image size:** owner question open.

## Docs optimisation done 2026-10-27 (so you don't redo it)

STATUS 25 KB → about 9 KB (Done table archived in `STATUS-done.md`, board shows open work only, 4-line log entries, owner decisions condensed); root `CLAUDE.md` tightened and its done-bookkeeping changed (no Done row; the task file is the record, Outcome starts with `Verified:`); `shell/CLAUDE.md` 12 KB → about 7 KB, how-tos moved to `shell/PATTERNS.md`; `tasks/README.md` and `PLANNING.md` stop repeating `LEAD.md`; `scripts/lint-board.ps1` enforces that the board and the task headers agree; size budgets are in `LEAD.md` step 3b. Not touched on purpose: the specs (`02-shell.md` is 25 KB: next candidate if builders keep reading it whole) and `dev-setup.md` (22 KB, linked from tasks only when needed).

## First things the next lead should do

1. Ask the owner about the disk; if fixed, run the VM drill (`docs/dev-setup.md`) and redo T-131's VM check.
2. Steps 1–3 of `LEAD.md` over the range above (T-138/T-139 are the interesting ones: the `Session1` contract is the base of the app launch story).
3. T-130 as the lead task when the VM works; then write the reserved VM tasks above.
4. Check the size budgets (`LEAD.md` 3b).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-10-22 | 91c4b89..ac93198 | T-101 | 0 / 1 (page host can't nest → T-111 hint) | 23 + 2 skipped | — |
| 2026-10-22 | ..ffd79bf | T-102 | 0 / 2 (Inbox) | 30 + 3 skipped | — |
| 2026-10-22 | ..b75bf66 | T-108, T-103, T-104, T-105 | 3 / 1 (offscreen gate, contract rule, planning lessons / probe → T-115) | 77 + 7 skipped | — |
| 2026-10-22 | image work | B-001, B-008 | 9 fixed (see dev-setup problem log) | 77 + 7 skipped | boot, update, rollback, greenboot ✅ |
| 2026-10-23 | 9ca4b25..c06c77a | T-115, T-116, T-106, T-117, T-122, T-107, T-120, T-121 + 2 plannings | 2 / 0 (mangled bytes + text lint, stale screenshots) | 101 + 9 skipped QML, 23 Rust | `0.0.6-lead1` and `-lead2` boot ✅, profiles over the bus ✅ |
| 2026-10-23 | beafbc6..da2d1be | T-114, T-124, T-125, T-109 (+ lead task T-123) | 2 / 1 (translation lint gap, stale services rule / shots focus → T-127) | 132 + 11 skipped QML, 23 Rust; shots 143 on re-run | `0.0.8-t123` boot ✅, compositor spike ✅ |
| 2026-10-24 | 1e5ae5e..4b811c6 | T-123 (lead), T-118, T-127, T-128 | 1 / 1 (T-118 delete order / pw-dump poll → T-133) | 133 + 11 skipped QML, 53 Rust (54 after the review test); shots 144 first run | see STATUS log |
| 2026-10-24 | 2aab79e..64b7e3f | T-119, T-131, T-110 (+ lead disk-space scripts) | 0 / 1 (job-signal race note for T-134) | 152 + 12 skipped QML; shots 164 | not run (WSL disk) |
| 2026-10-27 | 2f2f1e1..f7574e9 | T-129 (lead work), docs; + docs slimming, T-135..T-139 planned | 0 / 0 (T-129 screenshot fine; Forget rows sit below a long Wi-Fi list, cosmetic) | 164 + 13 skipped QML, 54 Rust; shots 177 (1 focus loss, recovered) | not run (WSL disk) |
