# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-29 "lead review 124ee1d..0fbe215"** (`git log --grep="lead review 124ee1d"`). Everything up to T-112 is reviewed.
- Next review: `git log --oneline <that commit>..HEAD`. Due after T-150, T-135, T-148 (the board says so).
- Last VM verification: image `0.0.18-lead` (lead, 2026-10-29, at `0fbe215`): `RUYA_BOOT_OK`, `qemu-img check` clean, `vm-store-check.sh` 41/41 PASS, `ruya-store` security 3.3. `ruya-session` and `ruya-library` are not in the image.

## Concerns (ranked)

1. **The compositor session is still the critical path**, now split: **T-150** (builder, NEXT: app layer + C++ `KeyRouter`, host-tested) then **T-130** (lead: `WaylandCompositor` wiring, unit, cage out, VM checks, drill). Review T-150 carefully: focus restoration and the Guide hold are the classic bug sources. Take T-130 in the first lead session after T-150 lands. Still no app has ever been launched from the shell.
2. **After T-130, write the reserved VM tasks:** `ruya-session` in the image (unit, policy, real spawner, Profiles1 fetch, `vm-session-check.sh`); `ruya-library` in the image, which first needs a decision **where it runs**: Steam libraries live in each profile user's home (ADR-004), so a system service would need read access to every home; a per-profile user service, or `ruya-session` handing the active profile's home to it, fits better. Decide with `ruya-session`. Then `ruya-update` over `bootc` (T-135 contract), BlueZ (T-136), udisks2 (T-137).
3. **`ruya-session` real spawner open questions** (T-139 Outcome): `systemd-run --user --machine=<user>@.host` from the service's user; per-profile Wayland socket location; reading exit code and `signaled` from the unit.
4. **Host storage integrity.** C: showed a zeroed cargo file and WSL `ext4` errors; T-140's builder saw two truncated `make-disk` outputs while WSL restarted. Always `qemu-img check` a fresh disk. Owner asked for a memory and SMART check.
5. **Store scale:** T-148 (service-side filter, `CatalogChanged`) must land before T-111; the shell re-read a 6 MB catalogue after every install.
6. **Admin authorization:** only `ruya-store` checks admin itself. Decide when T-135 lands whether every admin-only call verifies the same way.
7. **Mock-only surface:** Update (T-135), Bluetooth (T-136), Storage (T-137), Session client (T-138), Library client (T-113). At the limit (~4-5 waiting): don't add more contract+mock tasks until a real service catches up.
8. **Design system:** T-144 (contrast, weights) and T-145 (Inter) wait; canvas boards not compared with the spec yet (tell the owner which are stale once T-144/T-145 land).

## First things the next lead should do

1. `git status` clean, no builder session running, no `build.sh` in WSL (distro `FedoraLinux-44`).
2. CI of this push (`https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs?per_page=4`; no `gh` here; `curl` works from Git Bash).
3. Steps 1–3 of `LEAD.md` over the range above.
4. T-130 as the lead task if T-150 is done.
5. Size budgets: root `CLAUDE.md` 10.8 KB and `shell/CLAUDE.md` 7.2 KB sit at budget; trim before adding anything.

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
| 2026-10-29 | 124ee1d..0fbe215 | T-143, T-140, T-112 | 3 fixed (`dev.ps1` picked devkitPro's cmake, `scan-secrets.ps1` its brace-expanding git: both now prefer the real tool; badge radius text) / 2 filed (Flatpak games all `app` → T-149, catalogue re-read → T-148) + T-130 split (host half T-150) | 178 + 13 skipped QML, 172 Rust; shots 191 | `0.0.18-lead` ✅ boot, store check 41/41 |
