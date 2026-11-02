# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: `9b77857`** ("image: ruya-shell is the Wayland compositor, cage removed (T-130)"). Builder work is reviewed up to T-154 (lead review `e5c2ab3..ac6e5b1`); T-130 is the lead's own work: read its diff once with fresh eyes at the next review (`shell/compositor/`, `KeyRouter::appHasFocus`, the unit and the udev rule).
- Next review: `git log --oneline 9b77857..HEAD`, after 3-5 builder tasks.
- Last VM verification: `0.0.26-t130` / `0.0.27-t130` (lead, 2026-11-02): fresh disk `RUYA_BOOT_OK` with no cage, wizard and picker over the real bus, the T-123 key sequence and a held Guide over a Wayland test client (`vm-app-check.sh`), update, manual rollback, and greenboot's automatic rollback of a broken compositor (4 failed boots, then FALLBACK). `ruya-session` and `ruya-library` are still not in the image.

## Concerns (ranked)

1. **Write the `ruya-session` and `ruya-library` image tasks now: they are the new critical path.** T-130 is done; no app has been launched from the shell's own UI, and Home/Games are mock-only. `ruya-session` in the image: unit, bus policy, the real spawner (`systemd-run --user --machine=<user>@.host`, exit code and `signaled` from the unit: T-139 Outcome), the Profiles1 fetch, `vm-session-check.sh`, and **per-profile Wayland sockets** (Inbox: today's `ruya-0` lives in `ruya-shell`'s 0700 runtime directory, so a profile user cannot connect; `WaylandCompositor` can serve more sockets, or the session passes a connected fd). It must also define lock/sign-out with an app open (Inbox). `ruya-library`: per-profile user service or `ruya-session` hands it the profile's home (ADR-004; a system service reading every home is a privacy problem). Then BlueZ (T-136), udisks2 (T-137). T-147 (full-screen app flow) waits on `ruya-session` in practice, not only on T-130.
2. **Host disk space:** cleaned on 2026-11-02 (C: 13 → 44 GB free, D: 17 → 24 GB): podman pruned, the drill disk and the old ISO deleted, the WSL VHDX compacted from 39 to 7 GB by export/import. Each image session adds ~5-10 GB; follow "Free disk space" in `dev-setup.md` when C: or D: drops under ~15 GB. Older: C: showed a zeroed cargo file and WSL `ext4` errors; `qemu-img check` every fresh disk (clean on 2026-11-02).
3. **Compositor gaps (B-003 and Inbox):** suspend/resume and VT switching under eglfs are untested while the power menu offers Suspend; no dmabuf client, no blur over an app surface (the overlay dims the app instead), frame rates need a GPU. `Compositor.qml` has no qmllint and no Windows test: the image build (qmlcachegen) and `vm-app-check.sh` are its only checks, so any change there needs an image build.
4. **Nightly restart vs running apps.** The service restarts at 03:00-05:00 after 30 idle minutes with no app; "no app" is the shell's `appOpen` (now true for real Wayland clients). T-147 must keep apps left behind Home in `apps`. T-159 adds the on-screen notice.
5. **High-risk permission gate is enforced by the shell only** (T-152/T-156): acceptable while the shell is the only Store1 caller (bus policy: shell and root).
6. **Admin authorization:** `caller_is_admin` is copied in `ruya-store` and `ruya-update`; share it when a third service needs it.
7. **Design system:** T-157 (icon font) unblocks T-158 (hint bar) and T-161 (battery). T-144 (contrast) and T-145 (Inter) wait. Canvas boards stale on `AppArt`, the progress bar, `GlassPill`, `HeroBlock`, the buttons, the section nav, §3.7 icons.

## First things the next lead should do

1. `git status` clean, no builder session running, no `build.sh` in WSL (distro `FedoraLinux-44`).
2. CI of this push (`https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs?per_page=4`; no `gh` here; `curl` works from Git Bash). The CI `image` job now builds the compositor (`qt6-qtwayland-devel`) and boots it under KVM: the first run of that is this push.
3. Planning: turn concern 1 and the three T-130 Inbox lines into tasks (`Owner: lead` for the `ruya-session` image task: VM debugging and security), and put them high on the board.
4. Check T-157's subset script and pinned download (commit + SHA-256) if it has landed: the first build input fetched from the internet.
5. Size budgets: root `CLAUDE.md` 10.9 KB and `shell/CLAUDE.md` 7.3 KB sit at budget; STATUS about 10 KB. T-130's task file is 11.6 KB (its Outcome is the VM evidence; leave it).
6. Run `ssh`/`scp` with `-o UserKnownHostsFile=NUL` from the PowerShell tool: that `ssh` is Git's msys build and writes a real file `NUL` in the working directory (now git-ignored).

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
| 2026-11-02 | 39b25f2..9b77857 (no builder work) | T-130 (lead task) | 0 / 3 filed (Inbox: per-profile sockets, apps before sign-in, suspend under eglfs) + host disk space to the owner. Process: drill step 5 recipe, `/NUL` git-ignored | 256 + 21 skipped QML (35 s); shots 56 (42 s) | `0.0.26-t130` fresh disk ✅, T-123 sequence ✅, update + rollback ✅, greenboot auto-rollback ✅ |
