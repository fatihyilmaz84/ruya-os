# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-28 "lead review f835519..7392be4"** (`git log --grep="lead review f835519"`). Everything up to T-134 is reviewed and VM-verified.
- Next review: `git log --oneline <that commit>..HEAD`. Due after 3 builder tasks (the board says so).
- Last VM verification: image `0.0.17-t134` (2026-10-28): `RUYA_BOOT_OK`, `vm-devices-check.sh` (audio, network, events) and `vm-store-check.sh` all PASS, NIC unplug followed live by the service and the shell's `Network` client. No `ext4` errors in WSL.

## Concerns (ranked)

0. **Concurrent builder sessions (2026-10-28).** The owner started two "Next 3 tasks" builder sessions in the same checkout. They worked on T-132, T-133 and T-134 at once, left everything uncommitted with no Outcomes, and kept waking up whenever a background build they had started finished: one booted a VM at the same moment the lead did. The rule exists (CLAUDE.md step 1, LEAD.md); the problem was how sessions were started, so it is in the owner report, not a new rule. If it happens again, add an automated guard (e.g. `dev.ps1` refusing to build or boot while another session's lock file in `output/` is fresh). Lead tip: a builder's background job (`build.sh && make-disk.sh`) re-invokes that session when it ends; check `wsl ... pgrep -af build.sh` before assuming a builder is done.
1. **T-130 `[lead]` is the critical path** (compositor session replaces cage). No app has been launched from the shell yet; Phase 1's exit "overlay over a running app" waits on it. Then write the reserved VM tasks: `ruya-session` in the image (unit, polkit, per-profile Wayland/PipeWire sockets per ADR-004/010, spawner, `ambient`/`media` levels, Store "Open"); `ruya-update` over `bootc` (contract T-135, greenboot rollback event); BlueZ in `ruya-devices` (contract T-136); udisks2 (contract T-137).
2. **Store realism:** T-140 (Flathub instead of Fedora's OCI remote, AppStream refresh, real progress) should land before or with T-111 (Store UI), or the UI will be tuned to a catalogue of 524 unnamed apps. The job-signal race is mitigated by a 100 ms start delay in `ruya-store`; T-111's hint asks the client to buffer unknown-job signals as well.
3. **VM screenshots of Settings need a wizard walk:** T-132 used a probe instead (`scripts/vm-network-probe.qml`). T-141 scripts it; after that, insist on VM screenshots again for service tasks with a pane. Probes must use `console.warn`: the image filters `console.log`.
4. **Admin authorization:** `ruya-store` now checks admin for `AddRemote` itself (caller uid 0, or the active profile is an admin per `Profiles1`). Other services still trust the shell. Decide when T-135 (update) lands whether every admin-only call verifies the same way (security invariant territory).
5. **Mock-only surface:** Update (T-135), Bluetooth (T-136), Storage (T-137), Session (T-138) are contract-and-mock tasks with real services waiting. Keep at most about 4 waiting; check the mocks against the services when those land.
6. **`shots` focus flakes:** T-127's guard works; watch `TEST WINDOW LOST ACTIVATION` frequency.
7. **CI** not read since the 2026-10-27 push; this session's commits are unpushed (owner decision).
8. **Real hardware (B-002), image size:** owner question open.

## First things the next lead should do

1. `git status` clean and no builder session running (`list_sessions`, and no `build.sh` in WSL).
2. Steps 1–3 of `LEAD.md` over the range above; T-138/T-139 are the interesting ones (the `Session1` contract is the base of the app launch story).
3. T-130 as the lead task; then the reserved VM tasks above.
4. Size budgets (`LEAD.md` 3b): root `CLAUDE.md` is 10.7 KB, at its budget; trim before adding anything.

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
| 2026-10-28 | f835519..7392be4 + uncommitted | T-132, T-133, T-134 (builders stopped undocumented; lead verified and committed) | 0 code / 3 filed (Fedora remote → T-140, VM nav → T-141, signal buffering → T-111) + process (concurrent builders → owner) | 164 + 13 skipped QML, 117 Rust; shots not run (no screen changed) | `0.0.17-t134` ✅ devices, network link test, store, shell clients over the bus |
