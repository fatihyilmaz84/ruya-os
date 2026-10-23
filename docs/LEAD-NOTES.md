# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-24 "lead review 1e5ae5e..4b811c6"** (find it with `git log --grep="lead review 1e5ae5e"`). Everything up to T-128 is reviewed, including the `review:` fix for T-118.
- **Next lead reviews:** `git log --oneline <that commit>..HEAD`.
- Last VM verification: by the lead, image `0.0.11-lead` (see the STATUS log entry of 2026-10-24 for the result); before that T-128's `0.0.10-t128`.

## Concerns (ranked)

1. **T-130 `[lead]` is the critical path** (compositor session replaces cage). Phase 1's exit criterion "overlay over a running app" and everything app-related (`ruya-session`, store installs that launch, games) wait on it. Do it as the lead task next session if nothing is on fire. After it: write the `ruya-session` task (per-profile Wayland and PipeWire sockets, ADR-004/010; also where `ambient`/`media` levels get applied).
2. **`ruya-store` (B-004) needs a design call before it's a task:** libflatpak through gir bindings is not pure Rust and won't build on Windows; driving the `flatpak` CLI is the T-128-style alternative. Decide (lead, inside ADR-005) once T-110's contract exists, then write the task with a VM criterion that installs something small (a local test repo, not a Flathub runtime download).
3. **`ruya-devices` cost and growth.** T-133 removes the 1 s `pw-dump` poll; T-132 adds NetworkManager to the same binary and a polkit rule. Check that rule is narrow, and the hardening score stays "OK".
4. **Integration vs UI ratio is good now:** T-131 (VM criterion), T-132, T-133 are integration. Keep every new mock-only UI task paired with its service task.
5. **`shots` focus flakes:** T-127's guard; the lead's run was clean (144, no loss logged). If `TEST WINDOW LOST ACTIVATION` keeps appearing, look at what the desktop does, not the tests.
6. **CI** not checked since the T-122 run; nothing pushed since. Read the first run after the owner's next push (text/translation lints, the new crate).
7. **Image size, real hardware (B-002)**: unchanged, owner question open.

## First things the next lead should do

1. Steps 1–3 of `LEAD.md` over the range above (expect T-119, T-131, T-110, T-129).
2. T-130 as the lead task.
3. The `ruya-store` design call (concern 2), then its task.

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
