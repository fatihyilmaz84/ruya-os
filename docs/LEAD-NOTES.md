# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-28 "lead review 070e312..8e7a7fc"** (`git log --grep="lead review 070e312"`). Everything up to T-142 is reviewed.
- Next review: `git log --oneline <that commit>..HEAD`. Due after 3 builder tasks (the board says so).
- Last VM verification: image `0.0.17-t134` (2026-10-28): `RUYA_BOOT_OK`, `vm-devices-check.sh` and `vm-store-check.sh` all PASS; T-141's `vm-goto.ps1` ran on it. Nothing under `image/` changed since; `ruya-session` is not in the image.

## Concerns (ranked)

1. **T-130 `[lead]` is the critical path** (compositor session replaces cage). Still no app launched from the shell; Phase 1's exit "overlay over a running app", T-147 and the `ruya-session` VM task wait on it. Take it as the lead task in the next session that has time (it was not started on 2026-10-28). Then write the reserved VM tasks: `ruya-session` in the image (unit, policy, hardening, the real spawner from `launch_command`, Profiles1 fetch, `vm-session-check.sh`); `ruya-update` over `bootc` (T-135); BlueZ (T-136); udisks2 (T-137).
2. **`ruya-session` real spawner, open questions** (T-139 Outcome): does `systemd-run --user --machine=<user>@.host` work from the service's user; where the per-profile Wayland socket lives; how exit code and `signaled` are read from the unit. The exit-reason rules assume `signaled` is true for a SIGTERM death and that `kill` is a SIGKILL of the cgroup.
3. **Host storage integrity.** A cargo registry file on C: turned into null bytes, after WSL `ext4` errors (also on C:). Owner asked to run a memory and SMART check. `lint-text.ps1` catches null bytes in tracked files.
4. **Design system rollout.** T-143 (spacing/shape + `Badge`) next; T-144 now also applies the type weights with a lint. T-111/T-113 after T-143. Canvas boards not compared with the spec yet: tell the owner which are stale after T-143.
5. **Store realism:** T-140 before or with T-111.
6. **Admin authorization:** only `ruya-store` checks admin itself. Decide when T-135 lands whether every admin-only call verifies the same way.
7. **Mock-only surface:** Update (T-135), Bluetooth (T-136), Storage (T-137), Session client (T-138). Keep at most about 4 waiting.
8. **Real hardware (B-002):** owner question open.

## First things the next lead should do

1. `git status` clean and no builder session running (and no `build.sh` in WSL; the distro is `FedoraLinux-44`).
2. CI of this push (public API: `https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs?per_page=4`; no `gh` here).
3. Steps 1–3 of `LEAD.md` over the range above. T-143 touches many QML files: check the spacing lint has a self-check and the screenshots of every screen.
4. T-130 as the lead task.
5. Size budgets: root `CLAUDE.md` 10.8 KB and `shell/CLAUDE.md` 7.1 KB sit at budget; trim before adding anything.

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
| 2026-10-28 | f5b1a90..198e9ab | T-138, design-system docs (ADR-012, T-142..T-147) | 3 fixed (untested launch-failed toast, frozen-copy `tryCompare`, red CI clippy) + system fix (CI pinned to host Rust) | 169 + 13 skipped QML, 117 Rust; shots not run (no screen changed) | not run (no image change) |
| 2026-10-28 | 070e312..8e7a7fc | T-139, T-141, T-142 | 2 fixed (SIGTERM-after-Stop reported `killed`, spec mapping text) / 1 filed (weights → T-144, with a lint) | 172 + 13 skipped QML, 143 Rust; shots 185 | not run (no image change) |
