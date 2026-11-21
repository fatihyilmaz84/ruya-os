# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State during lead-39 (Opus, 2026-11-21, overnight, owner asleep: ".play first, keep going"; the Dell is offline)

- **Review range:** 6a4b709f..HEAD (this session). **Paper Plane `changes` cursor:** 6890 at the start.
- **Merged and Done so far (5 + 1 lead fix):** RUY-35 (Steam uses GE-Proton; Unix tests run in WSL first), RUY-36 (developer chapter `windows-games.md`, `samples/hello-runner`, runner-manifest lint; 2 rounds), RUY-854 (.play apps in the per-app permission list; ruya-store `sync_installed` listed late installs; `AppName.of`, `Library.itemForApp`; 2 rounds), RUY-37 (Wine11 = Kron4ek vanilla WoW64 wine-11.0, licence texts shipped via the pin folder's `licences/`, build fails without a licence text, GE-Proton retention test, licence limit 128 -> 256 bytes; 2 rounds). Lead fix: RUY-891 (tst_wallpaper flake: the USB tiles are listed asynchronously). Last gate on main 45cac132: **2316 passed, 0 failed**.
- **Image 0.0.97** (at cb70497f) built (CHAIN OK, 39 + 34 min). VM queue: **24 of 28 PASS** (RUY-390 comment has the list). Real failure: GE-Proton's protonfixes crashes outside Steam (no `PWD`, no Steam game id) -> **RUY-969** (high, in flight). `vm-runner-check.sh steam` needs Steam installed by hand.
- **Lead decisions:** RUY-37 split (image side) / **RUY-959** (Library1 ListRunners, per-profile runner choice, ResolveRunner; About reads it). **RUY-923**: a new pure crate `services/ruya-flatpak` for Flatpak argument lists (RUY-926's keyfile reader moves there next). RUY-914: Inspect serves `signer_name` (self-asserted, always beside the key) and `age_label` (same function as Library1). RUY-969's environment: `SteamAppId=0`, `SteamGameId=0`, `PWD`=cwd, protonfixes stays on. RUY-913 waits for the first splash-progress ticket.

## In flight (worktrees under D:\dev\RuyaOS-worktrees)
1. **RUY-959** (Opus builder): done round 1 (8282da32); asked to merge main (conflicts with 35/36/37 in install-runners.sh, vm-runner-check.sh, test-vm-checks.sh, About) before review. Then ruya-reviewer + design reviewer (About with two runners).
2. **RUY-902** (VM launch modes; told not to work around RUY-969). **RUY-923** (ruya-flatpak). **RUY-969** (Proton env).
3. Ready next for .play: RUY-914, RUY-925 (game page Uninstall), RUY-904 (after 959), RUY-905 (canvas first, after 959).

## Next
Image 0.0.98 after 959/969/902/923 merge, then the VM queue: vm-runner-check check+sample (969, Wine11), vm-play-check perms (854), launch+launch-windows (902), remove (923), vm-library-check runners (959). `free-space.ps1` and a WSL compact after the chain (RUY-957). The inbox has ~165 tickets: a planning pass is overdue (owner wishlist 931-955 needs canvases).

## Concerns (ranked)
1. Proton launches outside Steam were never run end to end in the VM by the launcher (RUY-969, RUY-902).
2. D: fills with four Rust lanes (18 GB free twice tonight): `cargo clean` merged worktrees before removing them, and main's after a gate.
3. F:/WSL capacity (vhdx 68 GB after compact; F: 44 GB free before 0.0.97).
4. Duplicated helpers across crates: RUY-960 (safe_file/vdf), RUY-972 (per-profile store), RUY-926 (keyfile), RUY-961 (VM first_profile), RUY-965 (shell Library lookup).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-19/20 (lead-37) | 09c9c08..58bb188 | 11 tickets merged (8 branches) + 4 lead review commits; ADR-037/038 | rounds 2-3 on 855, 898, 900, 901, 890, 886/887 (all real) | 2275 passed, 0 failed | RUY-899 spike ALL PASS (0.0.96) |
| 2026-11-20/21 (lead-38) | 58bb188..6a4b709 | 5 tickets merged + 4 lead review/docs commits; RUY-915 owner decision | rounds 2-3 on 816, 744, 909, 35 (all real) | 2305 passed, 0 failed | 0.0.97 failed twice (musl package; F: full) |
| 2026-11-21 (lead-39, interim) | 6a4b709..45cac13 | 4 tickets merged + RUY-891 lead fix | round 2 on 36 (audit gaps, lint), 854 (duplicate rule), 37 (licence texts: real) | 2316 passed, 0 failed | 0.0.97: 24/28 PASS, protonfixes env (RUY-969) |
