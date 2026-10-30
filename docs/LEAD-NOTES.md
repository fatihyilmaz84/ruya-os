# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-10-30 "lead review 4671bb5..e863439"** (`git log --grep="lead review 4671bb5"`). Everything up to T-111 is reviewed.
- Next review: `git log --oneline <that commit>..HEAD`, after 3–5 builder tasks.
- Last VM verification: image `0.0.19-t148` (builder, 2026-10-29, at `668b612`): `RUYA_BOOT_OK`, `vm-store-check.sh` all passed. It contains T-135's `Profiles1.VerifyAdmin`, but nothing called it over the bus; T-111's early-job-signal replay in `DBusStoreBackend` is also unverified. `ruya-session`, `ruya-library` and `ruya-update` are not in the image.

## Concerns (ranked)

1. **T-130 is still not started and is the critical path.** T-150 (host half) is done and reviewed: `KeyRouter` takes Guide keys only while `appItem->hasActiveFocus()`. In T-130, give `focusApp` the item that really holds focus (the `ShellSurfaceItem` itself, or make the wrapper a `FocusScope`), or Guide will reach the app. Run T-130 as its **own lead session** (several image builds, the update drill and the broken-compositor rollback): it did not fit after this review. Still no app has ever been launched from the shell.
2. **After T-130, write the reserved VM tasks:** `ruya-session` in the image (unit, policy, real spawner, Profiles1 fetch, `vm-session-check.sh`); `ruya-library` in the image (decide where it runs: per-profile user service, or `ruya-session` hands it the active profile's home; ADR-004); then the scheduled-check/idle-reboot follow-up of T-151, BlueZ (T-136), udisks2 (T-137).
3. **`ruya-session` real spawner open questions** (T-139 Outcome): `systemd-run --user --machine=<user>@.host` from the service's user; per-profile Wayland socket location; reading exit code and `signaled` from the unit.
4. **Admin authorization, decided 2026-10-30:** services refuse admin-only calls unless the caller is root or the shell while the active profile is an admin (as `ruya-store`'s `AddRemote`); PINs are checked by the shell with `Profiles1.VerifyAdmin`. T-151 applies it to `Update1`. When a third service needs it, move the check into a shared crate.
5. **Host storage integrity.** C: showed a zeroed cargo file and WSL `ext4` errors; `make-disk` outputs came out truncated while WSL restarted. Always `qemu-img check` a fresh disk. Owner asked for a memory and SMART check.
6. **Mock-only surface:** Bluetooth (T-136), Storage (T-137), Session client (T-138), Library client (T-113); Update gets its service in T-151. Don't add more contract+mock tasks until a real service catches up.
7. **Design system:** T-144 (contrast, weights) and T-145 (Inter) wait; the Store detail page's description text (`textDim` over bright backdrop blobs) is a T-144 case. Canvas boards not compared with the spec yet; `AppArt` and the progress bar were added to `04` §5 this session, so the canvas "system components" board is stale on those two.
8. **Store cards** look their app up with `Store.catalogue.find()` per delegate (`StorePage.qml`): fine while ListViews create only visible delegates; watch it if "Show all apps" feels slow on hardware.

## First things the next lead should do

1. `git status` clean, no builder session running, no `build.sh` in WSL (distro `FedoraLinux-44`).
2. CI of this push (`https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs?per_page=4`; no `gh` here; `curl` works from Git Bash).
3. If the owner starts a lead session for T-130: claim it and do it (concern 1). Otherwise steps 1–3 of `LEAD.md`.
4. Size budgets: root `CLAUDE.md` 10.9 KB and `shell/CLAUDE.md` 7.3 KB sit at budget; trim before adding anything.
5. Step 6b (retrospective): check that builders' `shots` now finish (screenshot-only, ~25 s); if a screenshot test fails alone but passed in the old full run, it leaned on an earlier test function: fix the test.

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
| 2026-10-30 | 4671bb5..e863439 | T-150, T-135, T-148, T-111 | 2 fixed (progress fill colour, `AppArt` + progress bar into `04` §5) / 0 filed; admin-check decision; T-151, T-152 planned. Process: `shots` screenshot-only (240 → 23 s), locked-screen refusal, bounded key loops + `lint-tests.ps1`, retrospective step 6b | 209 + 15 skipped QML, 178 Rust; shots 224, then 46 (screenshot-only) | not run (builder's `0.0.19-t148` covers the service changes) |
