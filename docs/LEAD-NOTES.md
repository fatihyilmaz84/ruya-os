# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-38 (Opus, 2026-11-20/21)

- **Review range:** 58bb1888..HEAD (reviewed this session). **Paper Plane `changes` cursor:** 6812.
- **Merged and Done (5):** RUY-903 (Library1 dry-run runner keys), RUY-34 (Play platform on /usr: static launcher, GE-Proton as runner data, tmpfiles links, About row; scope 4 split to RUY-916), RUY-816 (Play1.Remove; round 3 by the lead: `Play.inFlight`), RUY-744 (Settings > Privacy > App permissions; 3 rounds), RUY-909 (a re-commit never widens grants; 2 rounds). Last full test on main 7eb60ccc: **2305 passed, 0 failed**. **Pushed** (Linux CI job skipped: WSL down; GitHub CI not checked).
- **Owner decisions:** RUY-915 (2026-11-20): the image ships **GE-Proton (current + previous major) and Wine stable** only; staging, Wine-GE, UMU-Proton dropped (ADR-025/038, 05 amended; RUY-37 rescoped). **Domain: ruyaos.org** (in memory).
- **Lead decisions:** ADR-038 "a generation bump never widens a grant" (RUY-909). The launcher is **static glibc (crt-static)**, not musl: Fedora ships no musl Rust std (10d7be89; note for the next architect audit). 04: a fact row may have one note per item (≤ 3); a risk mark on a row is the words "High risk", no colour (warningText misses 4.5:1 on glass). All-devices withdrawal keeps input **and dri**.
- **ruyaos.org:** an agent wrote the online-services requirements (Laravel + Filament) in `D:\dev\ruyaos.org\` (69 requirements, 14 owner decisions, 11 repo follow-ups: RUY-930). The owner has not read it yet.

## In flight: read first
1. **RUY-35** (Changes Requested): round 2 was stopped mid-way at handoff. Worktree `D:\dev\RuyaOS-worktrees\RUY-35` holds **uncommitted** round-2 edits (a new `safe_file.rs`, steam_tool.rs, vdf.rs, usage_store.rs, Cargo). The round-2 list is on the ticket (reviewer's verdict + lead message: no-follow write helper, rank by runner.json via `ruya_play_launch::runners::scan_in` + `compare_versions`, the VM check must FAIL on a non-GE-Proton default). Dispatch a fresh builder on the branch with "finish round 2 from the uncommitted edits".
2. **WSL / F: disk.** `F:\wsl\ext4.vhdx` is 104.6 GB; F: filled, WSL went read-only and the 0.0.97 build crashed. Done: removed `F:\RuyaOS-tmp\ruyaos-0.0.94.oci` and `0.0.95.oci` (0.0.96 kept: the Dell's), removed `/var/tmp/buildah*` and old `/root` cargo targets (102 → 86 GB used inside). **Left:** `podman image prune -f`, remove unused tagged images (`ruy434-sat:dev`, `ruya-shell-build:t455`), the 5 orphaned anonymous volumes (14 GB, 0 active), `fstrim -av`, `wsl --shutdown`, `wsl --manage FedoraLinux-44 --compact`. `podman system check` was stopped (overlay is 65 GB vs 43 GB of images: a crash leftover; `podman system check --repair` if prune leaves it).
3. **Image 0.0.97 not built yet.** Then the VM queue (RUY-390 comments): vm-runner-check.sh check (RUY-34: watch absolute/hard links in the real GE-Proton tree), vm-library-check.sh play (903), vm-play-check.sh remove (816), vm-store-check.sh perms (744), plus lead-37's queue (855, 900, 886/887, RUY-890's five scripts).

## Next (.play path, RUY-780)
RUY-35 → RUY-36 (rewritten by lead-38; adds a vm-runner-check mode, so after 35) → RUY-37 (Wine stable, retention rule, per-game choice; About moves to the library's runner scan, runners.list goes) → RUY-904 → RUY-905 (canvas first; needs a Library1 ResolveRunner) → RUY-902 (VM launch end to end) → RUY-854. Spike RUY-916 (offline Platform runtime: installations.d vs sideload repo) is Ready, lead.

## Concerns (ranked)
1. F:/WSL capacity: one image build can fill the vhdx; compact after every build chain.
2. Builder budgets: RUY-744 538k in round 1, RUY-816 ~880k over two rounds. Wide tickets (contract + service + shell + VM) should be split before dispatch.
3. Three Flatpak metadata readers (RUY-926); two write_atomic copies in ruya-session (RUY-35 folds them).

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
