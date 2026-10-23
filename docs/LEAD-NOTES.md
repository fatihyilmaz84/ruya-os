# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-23** (`docs: lead review 9ca4b25..c06c77a; …`, find it with `git log --grep="lead review 9ca4b25"`). Everything from T-115 to T-122 is reviewed.
- **Next lead reviews:** `git log --oneline <that commit>..HEAD`.
- Last VM verification: 2026-10-23 by the lead, image `0.0.6-lead1` built from `c06c77a` (see the STATUS log entry), then T-126's hardened unit.

## Concerns (ranked)

1. **ADR-002 (compositor) is still open and blocks the Phase 1 exit** ("overlay over a running app"). It is now **T-123 `[lead]`**: a functional spike in the VM. Do it in the next lead session, before more shell UI piles up on cage assumptions.
2. **Audio ownership across users (B-007).** PipeWire runs per user; the shell's session has one, profile apps will run as other users (`ruya-session`, not yet designed). Decide whose PipeWire owns the outputs before the `ruya-devices` audio task is written. Ties into how `ruya-session` launches apps, so think about both together (maybe one ADR).
3. **Integration still lags UI**, but the gap is closing: T-120/T-121 proved the VM workflow. New rule in `PLANNING.md`: every service-facing task gets a VM acceptance criterion. B-004 (`ruya-store` service) can become a task as soon as T-110 lands.
4. **File corruption by host tools reached `main` twice** (T-107 cp1252, T-121 backslash escapes in `dev-setup.md`). Fixed by an automated check (`scripts/lint-text.ps1` in `dev.ps1 test` and CI). If anything similar slips through, extend that lint rather than adding prose.
5. **CI after this push.** `lint` gained a step (text lint under `pwsh` on Linux, never run there yet). Read the first run after the owner pushes.
6. **Image size (4.7 GB) and update sizes**: release topic, still unplanned (candidate list in the 2026-10-23 planning entry).
7. **Real hardware (B-002) untouched.** The owner has not said whether a spare PC exists.

## First things the next lead should do

1. Steps 1–3 of `LEAD.md` over the range above (expect T-114, T-124, T-125).
2. T-123 (compositor spike) as the lead task.
3. Decide concern 2 (audio/session ownership); then write the `ruya-devices` audio task.
4. If T-110 is done: write the `ruya-store` service task (VM-verified).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-10-22 | 91c4b89..ac93198 | T-101 | 0 / 1 (page host can't nest → T-111 hint) | 23 + 2 skipped | — |
| 2026-10-22 | ..ffd79bf | T-102 | 0 / 2 (Inbox) | 30 + 3 skipped | — |
| 2026-10-22 | ..b75bf66 | T-108, T-103, T-104, T-105 | 3 / 1 (offscreen gate, contract rule, planning lessons / probe → T-115) | 77 + 7 skipped | — |
| 2026-10-22 | image work | B-001, B-008 | 9 fixed (see dev-setup problem log) | 77 + 7 skipped | boot, update, rollback, greenboot ✅ |
| 2026-10-23 | 9ca4b25..c06c77a | T-115, T-116, T-106, T-117, T-122, T-107, T-120, T-121 + 2 plannings | 2 / 0 (mangled bytes + text lint, stale screenshots) | 101 + 9 skipped QML, 23 Rust | `0.0.6-lead1` and `-lead2` boot ✅, profiles over the bus ✅ |
