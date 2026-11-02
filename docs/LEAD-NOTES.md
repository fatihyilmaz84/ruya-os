# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: the lead commit of 2026-11-02 "lead review e5c2ab3..ac6e5b1"** (`git log --grep="lead review e5c2ab3"`). Everything up to T-154 is reviewed.
- Next review: `git log --oneline <that commit>..HEAD`, after 3–5 builder tasks.
- Last VM verification: image `0.0.25-t154` (builder, 2026-11-02): `RUYA_BOOT_OK`, `vm-update-check.sh` ALL PASSED, the scheduled 03:10 restart booted the staged image. The 2026-11-02 review fix (`schedule.rs` clock edge, shell activity report) has no VM run: pure core plus shell, covered by Rust and QML tests. `ruya-session` and `ruya-library` are not in the image; the shell's Library, Session and Update-activity D-Bus clients have never run.

## Concerns (ranked)

1. **T-130 is still not started and is the critical path** (fourth review in a row). Three update tasks landed instead; the update stack is now complete enough. Run T-130 as its **own lead session** (several image builds, the update drill, the broken-compositor rollback). `KeyRouter` takes Guide keys only while `appItem->hasActiveFocus()`: give `focusApp` the item that really holds focus (the `ShellSurfaceItem`, or make the wrapper a `FocusScope`). No app has ever been launched from the shell, and Home/Games are mock-only.
2. **After T-130, write the reserved VM tasks:** `ruya-session` in the image (unit, policy, real spawner, Profiles1 fetch, `vm-session-check.sh`); `ruya-library` in the image (per-profile user service, or `ruya-session` hands it the profile's home: ADR-004; a system service reading every profile's home is a privacy problem); then BlueZ (T-136), udisks2 (T-137).
3. **Nightly restart vs running apps.** The service restarts at 03:00–05:00 after 30 idle minutes with no app; "no app" is the shell's `appOpen` (review fix 2026-11-02: reported at once on change, not only with input). T-147 must keep apps left behind Home in `apps` (hint added). T-159 adds the on-screen notice.
4. **High-risk permission gate is enforced by the shell only** (T-152/T-156): the service trusts the shell (bus policy: shell and root). Acceptable while the shell is the only caller; revisit if another client (a web remote, an app portal) ever reaches Store1.
5. **`ruya-session` real spawner open questions** (T-139 Outcome): `systemd-run --user --machine=<user>@.host`; per-profile Wayland socket location; exit code and `signaled` from the unit.
6. **Admin authorization:** `caller_is_admin` is copied in `ruya-store` and `ruya-update`; share it when a third service needs it.
7. **Host storage integrity.** C: showed a zeroed cargo file and WSL `ext4` errors. Always `qemu-img check` a fresh disk. Owner asked for a memory and SMART check.
8. **Design system:** T-157 (icon font) unblocks T-158 (hint bar) and T-161 (battery). T-144 (contrast) and T-145 (Inter) wait. Canvas boards stale on `AppArt`, the progress bar, `GlassPill`, `HeroBlock`, the buttons, the section nav, §3.7 icons.

## First things the next lead should do

1. `git status` clean, no builder session running, no `build.sh` in WSL (distro `FedoraLinux-44`).
2. CI of this push (`https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs?per_page=4`; no `gh` here; `curl` works from Git Bash).
3. If the owner starts a lead session for T-130: claim it and do it (concern 1). Otherwise steps 1–3 of `LEAD.md`.
4. Check T-157's subset script and pinned download (commit + SHA-256) if it has landed: the first build input fetched from the internet.
5. Size budgets: root `CLAUDE.md` 10.9 KB and `shell/CLAUDE.md` 7.3 KB sit at budget. STATUS is now under 10 KB and `lint-board.ps1` holds the log to five entries of ≤ 700 characters: keep your own lead entry inside that too.

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
| 2026-11-01 | 300245c..e19899f | T-149, T-151, T-113, T-152, T-146 | 8 fixed (16:9 cards, Home pill ring, hero letter, first hero art, ArtCard test, `Theme.hairline`, 04 glass rows, comments) / 4 filed (T-153: rollback race, empty tag, fatal channel file; T-156: update adds high-risk permission). Process: parallel review subagents, geometry lesson | 242 + 20 skipped QML, 207 Rust (63 s); shots 55 (36 s) | not run (`0.0.21-t151` covers it) |
| 2026-11-02 | e5c2ab3..ac6e5b1 | T-153, T-156, T-154 | 2 fixed (future `last_check` stopped the daily check; app start/close swallowed by the once-a-minute report) / 0 filed; Inbox 5 → T-159, T-160, T-161, T-147 hint. Process: `lint-board.ps1` caps the session log (STATUS was 11.3 KB) | 255 + 21 skipped QML, 242 Rust (52 s); shots 56 (39 s) | not run (`0.0.25-t154` covers it; review fix is core + shell) |
