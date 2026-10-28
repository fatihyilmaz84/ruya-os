# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-28 "lead review f5b1a90..198e9ab"** (`git log --grep="lead review f5b1a90"`). Everything up to T-138 and the design-system docs is reviewed.
- Next review: `git log --oneline <that commit>..HEAD`. Due after 3 builder tasks (the board says so).
- Last VM verification: image `0.0.17-t134` (2026-10-28): `RUYA_BOOT_OK`, `vm-devices-check.sh` and `vm-store-check.sh` all PASS. Nothing under `image/` or `services/` changed since, except a one-line clippy fix in `ruya-store` (same behaviour).

## Concerns (ranked)

1. **T-130 `[lead]` is the critical path** (compositor session replaces cage). No app has been launched from the shell; Phase 1's exit "overlay over a running app" and T-147 (full-screen apps) wait on it. Then write the reserved VM tasks: `ruya-session` in the image (unit, polkit, per-profile Wayland/PipeWire sockets per ADR-004/010, spawner, `ambient`/`media` levels, Store "Open"); `ruya-update` over `bootc` (contract T-135); BlueZ (T-136); udisks2 (T-137).
2. **Host storage integrity.** A cargo registry file on C: turned into null bytes (2026-10-28), after the WSL `ext4` errors of 2026-10-24..27 (also on C:). Owner asked to run a memory and SMART check. If a tracked file ever shows null bytes, `lint-text.ps1` catches it; for caches, delete and re-fetch.
3. **CI drift.** CI was red from `81ce23e` until this push because the runner's clippy (1.99) knew a lint the host's (1.92) did not. CI is now pinned to 1.92.0 (`ci.yml`, `dev-setup.md`); **check the first run after this push is green** (public API: `https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs?per_page=4`, no `gh` on this host). The `image` job failed once at `f835519` and passed at `2e280ef`.
4. **Design system rollout.** You are its steward (`LEAD.md` §5). T-142 (type scale + size lint) and T-143 (spacing/shape + `Badge`) come first; T-111 and T-113 should land after T-143 so they use the tokens. T-146/T-147 are the owner's art-led Home and full-screen flow. The canvas boards have not been compared with the spec since it was written: tell the owner which are stale once T-142/T-143 land.
5. **Store realism:** T-140 (Flathub, AppStream refresh, real progress) before or with T-111.
6. **Admin authorization:** only `ruya-store` checks admin itself. Decide when T-135 lands whether every admin-only call verifies the same way.
7. **Mock-only surface:** Update (T-135), Bluetooth (T-136), Storage (T-137), Session (T-138, service T-139). Keep at most about 4 waiting.
8. **Real hardware (B-002):** owner question open.

## First things the next lead should do

1. `git status` clean and no builder session running (`list_sessions`, and no `build.sh` in WSL; the distro is `FedoraLinux-44`).
2. Read the CI result of this push (concern 3).
3. Steps 1–3 of `LEAD.md` over the range above; T-139 (`ruya-session` core) is the interesting one: check the mock and the Rust core agree on every status and reason, including `launch-failed`.
4. T-130 as the lead task.
5. Size budgets (`LEAD.md` 3b): root `CLAUDE.md` 10.8 KB, `shell/CLAUDE.md` 7.0 KB, at budget; trim before adding anything.

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
