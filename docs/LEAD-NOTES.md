# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-23 "lead review beafbc6..da2d1be"** (find it with `git log --grep="lead review beafbc6"`). Everything up to T-109 is reviewed.
- **Next lead reviews:** `git log --oneline <that commit>..HEAD`.
- Last VM verification: by builders, images `0.0.6-t124` and `0.0.7-t109` (`RUYA_BOOT_OK`); by a lead, `0.0.6-lead2` (T-126).

## Concerns (ranked)

1. **ADR-002 (compositor) still open; it blocks the Phase 1 exit** ("overlay over a running app") and the per-profile Wayland socket that `ruya-session` needs (ADR-004, ADR-010). T-123 `[lead]` was not started in this session; it is the first lead task next time. More shell UI keeps landing on cage assumptions meanwhile.
2. **ADR-010 is decided on paper only.** The risky parts: owning a *system*-bus name from a *user* unit (T-128 hints), and giving profile apps a socket to the shell's PipeWire (not designed until `ruya-session`). If T-128 finds the user-unit model unworkable, revisit the ADR rather than letting the builder improvise.
3. **`shots` focus flakes** (three in a day). T-127 should make them self-explaining. If they persist after T-127, consider running `shots` only on an idle desktop and saying so in `CLAUDE.md`.
4. **Integration still lags UI.** Two of the next five tasks are service/VM work (T-118, T-128). Keep that ratio: every mock-only UI task (T-129, T-111) should have its service task on the board soon after.
5. **`ruya-store` service (B-004)** becomes a task once T-110 lands (VM-verified, like T-128).
6. **CI** not checked since the T-122 run; the text and translation lints added later have not run on GitHub yet. Read the first run after the owner's next push.
7. **Image size (4.7 GB), update sizes, real hardware (B-002)**: unplanned; the owner hasn't said whether a spare PC exists.

## First things the next lead should do

1. Steps 1–3 of `LEAD.md` over the range above (expect T-118, T-127, T-128, T-119).
2. T-123 (compositor spike) as the lead task.
3. Check T-128 against ADR-010 (unit type, D-Bus policy, hardening score).
4. If T-110 is done: write the `ruya-store` service task.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-10-22 | 91c4b89..ac93198 | T-101 | 0 / 1 (page host can't nest → T-111 hint) | 23 + 2 skipped | — |
| 2026-10-22 | ..ffd79bf | T-102 | 0 / 2 (Inbox) | 30 + 3 skipped | — |
| 2026-10-22 | ..b75bf66 | T-108, T-103, T-104, T-105 | 3 / 1 (offscreen gate, contract rule, planning lessons / probe → T-115) | 77 + 7 skipped | — |
| 2026-10-22 | image work | B-001, B-008 | 9 fixed (see dev-setup problem log) | 77 + 7 skipped | boot, update, rollback, greenboot ✅ |
| 2026-10-23 | 9ca4b25..c06c77a | T-115, T-116, T-106, T-117, T-122, T-107, T-120, T-121 + 2 plannings | 2 / 0 (mangled bytes + text lint, stale screenshots) | 101 + 9 skipped QML, 23 Rust | `0.0.6-lead1` and `-lead2` boot ✅, profiles over the bus ✅ |
| 2026-10-23 | beafbc6..da2d1be | T-114, T-124, T-125, T-109 | 2 / 1 (translation lint gap, stale services rule / shots focus → T-127) | 132 + 11 skipped QML, 23 Rust; shots 143 on re-run | not re-run (builders' images boot) |
