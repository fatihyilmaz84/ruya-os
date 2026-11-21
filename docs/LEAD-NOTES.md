# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-38 (Opus, 2026-11-20/21)

- **Review range:** 58bb1888..HEAD (reviewed this session). **Paper Plane `changes` cursor:** 6812.
- **Merged and Done (5):** RUY-903 (Library1 dry-run runner keys), RUY-34 (Play platform on /usr: static launcher, GE-Proton as runner data, tmpfiles links, About row; scope 4 split to RUY-916), RUY-816 (Play1.Remove; round 3 by the lead: `Play.inFlight`), RUY-744 (Settings > Privacy > App permissions; 3 rounds), RUY-909 (a re-commit never widens grants; 2 rounds). Last full test on main 7eb60ccc: **2305 passed, 0 failed**. **Pushed**; GitHub CI green on main (ci + supply-chain, b919daf8); the local Linux CI job passed at b919daf8.
- **Owner decisions:** RUY-915 (2026-11-20): the image ships **GE-Proton (current + previous major) and Wine stable** only (ADR-025/038, 05; RUY-37 rescoped). **Domain: ruyaos.org.** 2026-11-21: **after RUY-902, the goal RUY-956 "Steam is first-class"** comes next (memory updated); a PIN profile asks its PIN after a wake (ADR-017 amendment 8, RUY-953); registry `registry.ruyaos.org/ruyaos` (01 §4); telemetry **opt-in from the first release** (RUY-386: privacy texts become release blockers); store starts first-party + curated Flathub; website on a DreamHost VPS (download hosting open); one legal review before release; signing keys as encrypted files for now, hardware tokens before release (RUY-385); the WSL vhdx stays on F: (RUY-957). Steam art from Steam's local files (RUY-958). All in `D:\dev\ruyaos.org\REQUIREMENTS.md` too.
- **Owner wishlist filed tonight (inbox, unplanned):** RUY-931 wallpaper per profile, 932-934 Home/Store/Games-grid redesigns (canvas first), 935 Wii U Pro battery, 936 power on the picker, 937 playlists, 938-948 Steam Input parity, 949 live backdrop by time/season, 950 "New" badge, 951-952 pad mic/speaker, 954 jagged Details icon, 955 flat status tray (only the bell stays glass). **The next session should start with a planning pass** (about 40 new inbox tickets).
- **Lead decisions:** ADR-038 "a generation bump never widens a grant" (RUY-909). The launcher is **static glibc (crt-static)**, not musl: Fedora ships no musl Rust std (10d7be89; note for the next architect audit). 04: a fact row may have one note per item (≤ 3); a risk mark on a row is the words "High risk", no colour (warningText misses 4.5:1 on glass). All-devices withdrawal keeps input **and dri**.
- **ruyaos.org:** an agent wrote the online-services requirements (Laravel + Filament) in `D:\dev\ruyaos.org\` (69 requirements, 14 owner decisions, 11 repo follow-ups: RUY-930). The owner has not read it yet.

## In flight: read first
1. **RUY-35: APPROVED (round 2), not merged.** Branch `t/RUY-35-steam-ge-proton` at **9b55d905** (worktree `D:\dev\RuyaOS-worktrees\RUY-35`, clean; the last commit is the lead's FIFO fix in `safe_file::read_below`, `dev.ps1 rust` green on Windows + Linux clippy). **Before the merge** run the Unix-only tests in WSL (reviewer's condition): from `services`, `CARGO_TARGET_DIR=/tmp/ruy35 cargo test -p ruya-session` (safe_file link + FIFO tests, steam_tool). Then merge, merge gate (full test: main moved), Done, `vm-runner-check.sh steam` to the VM queue, remove the worktree. Inbox from it: share `safe_file`/`vdf.rs` across crates (ruya-library reads Steam files too, RUY-958).
2. **WSL / F: disk.** Cleaned inside WSL (102 → 64 GB used: old OCI 0.0.94/0.0.95 on F: deleted, buildah temp dirs, old cargo targets, two old images, 5 orphan volumes, `podman system check --repair`, fstrim). **`wsl --manage FedoraLinux-44 --compact` was running at handoff** (started 01:09, slow on USB; the vhdx was 104.6 GB before). Check `(Get-Item F:\wsl\ext4.vhdx).Length` and F: free first; WSL can't start while it runs. The next image build may be slower (orphan volumes removed).
3. **Image 0.0.97 not built yet.** Then the VM queue (RUY-390 comments): vm-runner-check.sh check (RUY-34: watch absolute/hard links in the real GE-Proton tree), vm-library-check.sh play (903), vm-play-check.sh remove (816), vm-store-check.sh perms (744), plus lead-37's queue (855, 900, 886/887, RUY-890's five scripts).

## Next (.play path, RUY-780)
Merge RUY-35 → RUY-36 (rewritten by lead-38; adds a vm-runner-check mode, so after 35) → RUY-37 (Wine stable, retention rule, per-game choice; About moves to the library's runner scan, runners.list goes) → RUY-904 → RUY-905 (canvas first; needs a Library1 ResolveRunner) → RUY-902 (VM launch end to end) → RUY-854. Spike RUY-916 (offline Platform runtime: installations.d vs sideload repo) is Ready, lead.

## Concerns (ranked)
1. F:/WSL capacity: one image build can fill the vhdx; compact after every build chain (RUY-957, high).
2. Steam cluster (RUY-956) and wake reliability (RUY-786 with RUY-953) are the most user-visible gaps; release prep has no goal yet (RUY-15, RUY-20, RUY-918, RUY-917): propose a "First release" formation.
3. Builder budgets: RUY-744 538k in round 1, RUY-816 ~880k over two rounds. Wide tickets (contract + service + shell + VM) should be split before dispatch.
4. Three Flatpak metadata readers (RUY-926); safe_file/vdf in ruya-session only (RUY-35).

## Process changes in lead-38
- **Lead:** a round past the budget goes to a fresh builder with a written round list on the ticket (RUY-744) or is done by the lead (RUY-816 round 3); a builder's own inbox line that closes a gap in its ticket goes back to it (RUY-816's card row).
- **Tests:** the shard-runner self-check flakes under load (RUY-928); revert-check has no mode for rootfs data files (RUY-929). A red gate is rerun once with a log before reverting (it was the flake).
- **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-19 (lead-36) | d0b97cd..09c9c08 | 17 tickets merged (16 branches) + 4 lead review commits + 3 docs commits; filed 878-896 | 869, 871, 884, 889, 888: round 2 (all real); 2 gate load flakes | 2274 passed, 0 failed (last gate) | 0.0.95/0.0.96: .play queue all PASS |
| 2026-11-19/20 (lead-37) | 09c9c08..58bb188 | 11 tickets merged (8 branches) + 4 lead review commits; ADR-037/038; RUY-100/899/906 closed; filed 897-914 | rounds 2-3 on 855, 898, 900, 901, 890, 886/887 (all real); 1 red gate from a merge-order clash | 2275 passed, 0 failed (last) | RUY-899 spike ALL PASS (0.0.96) |
| 2026-11-20/21 (lead-38) | 58bb188..HEAD | 5 tickets merged + 4 lead review/docs commits; RUY-915 owner decision; RUY-909 ADR; filed 915-930 | rounds 2-3 on 816, 744, 909, 35 (all real: race, fail-open restore, fail-open parser, sandbox write); 1 gate flake | 2305 passed, 0 failed | 0.0.97 failed twice (musl package; F: full) |
