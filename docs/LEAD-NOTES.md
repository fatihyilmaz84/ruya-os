# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2)**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-35 (Opus, 2026-11-18)

- **Review range:** 486cc142..HEAD. **Paper Plane `changes` cursor:** 5043 (read at start; no changes then).
- **Stopped by budget:** the 5-hour window reached 91 % (reset 23:20). No lanes, no builder worktrees open. The four leftover folders under `D:\dev\RuyaOS-worktrees` (RUY-862) could not be deleted (the permission check refused it).
- **Merged (all `.play`, owner: ".play first"):** RUY-866 (lead: helpers get their real state folder, staging/inspect on the helpers' mount, failed jobs log their problems), RUY-861 + 848 (`source.unreadable`; a top-level `.ref` is `package.reserved_ref`), RUY-863 + 865 (one origin check `reconcile::ours`; `perms` uninstalls first), RUY-853 + 864 (the install sheet follows the gate, "The update adds", the mock's high-risk pair), RUY-856 (.play logo, art roles, trust row, signer, trailer on Home and the game page). Every merge gate green (last: 2247 passed, 0 failed). Rounds: 866, 853, 856 took 2; 861, 863 approved first time.
- **Owner rule (2026-11-18):** contributors and the lead are the codebase's maintainers (CLAUDE.md Working style, LEAD.md).

## The .play VM state
- **0.0.93** (46dcb90e): `helper` PASS 10/0 (ADR-036 works); `check` 29/7: every install that passed inspection failed with `staging.io` "Not a directory". Cause found in the VM (tracefs): the helper was given systemd's `/var/lib/<unit>` link; the next wall was an EXDEV rename between the service's separate mounts. Fixed by RUY-866.
- **0.0.94** (389b7e97: 866 + 861 + 863, not 853/856): **signed USB installs work end to end** (`check` 33/2, `helper` 9/0; RUY-100 comment). FAILs: Library1 did not list the app right after the install (**RUY-876**, lead, high); no profile on the VM for the launch step. `verify`/`perms`/`library play` re-install the same id unsigned after key A owned it, so `different-developer` by design (**RUY-877**, high: own id per mode). RUY-866 Done.
- Still unproven in the VM: Verify (RUY-834), the permission mapping (RUY-851, 863's `perms`), the Library listing (RUY-852): all wait for RUY-877, then a run on an image with 853/856 (RUY-390). The Flatpak `deploy` layout RUY-863 reads was confirmed on the Dell (origin first, NUL-terminated).

## First thing next session
1. RUY-877 (a builder, scripts only) and RUY-876 (lead: reproduce in the VM, likely ruya-library) first; then an image from HEAD (has 853 and 856) and the full `.play` VM queue. When `check`, `verify` and `perms` pass, RUY-100 is proven: unblock RUY-102/104's children.
2. `.play` lanes next (all Backlog, need a lead review and `Ready`): RUY-869 (unpack run's missing vs unreadable), RUY-870 (launcher/share refused early, with RUY-835's ruya-pack side), RUY-871 (origin follow-ups), RUY-872 (Library1 screenshots, what's new, signer key id: contract first), RUY-873 (art fallbacks on splash, close card, quick menu, screen saver), RUY-875 (mock tiers, shot order), RUY-867 (old staging folder). Then RUY-101 (runners), RUY-103 (updates).
3. Design decision for the lead: RUY-874 (genre tint for the .play hero; 04 has no token).
4. RUY-868: an enforcing `nnp_transition` denial from `ruya-devices` (and permissive bootupd reads) seen in the 0.0.93 boot.
5. Dell is on 0.0.92. Update it to 0.0.94 (the oci is on F:) once the VM checks pass. Still open from lead-34: the pad test in Neverball/Starfighter, and the old `.claude/worktrees/design-pad-silhouettes-559410` (its usage hooks double Paper Plane's events).

## Owner direction (in force)
- **.play first (2026-11-18):** `.play` lanes before any other goal (memory `play-packages-first`).
- **Maintainers (2026-11-18):** design for long-term ownership; no workarounds merged.
- **Performance goal, measure first:** formation RUY-558; RUY-842 (Dell baseline) blocks the tuning tickets.
- RUY-838 game options (design first); Steam first-class (RUY-815).

## Concerns (ranked)
1. `.play`: installs proven; the Library listing (RUY-876) and Verify/perms in the VM (RUY-877) are not.
2. D: space: Rust worktrees are about 11 GB each; see LEAD.md 4b.2.
3. Godot 3 X11 games (RUY-494), Steam focus (RUY-825/812).

## Process changes in lead-35
- **Lead:** D: filled twice with four lanes (two Rust): LEAD.md 4b.2 now says to check the space per lane and how to get it back. Lead-made fixes go to a reviewer too: RUY-866's VM script had a real bug the review caught. Merges wait while the image build reads the checkout (`podman build` on the working tree), and the gate waits for `make-disk`.
- **Builders:** none; two lost a run to the full disk, not to their code.
- **Tests:** `vm-play-check.sh`'s Inspect steps now fail on an internal fault in the record (the method said ok while it held `staging.io`), and its leftovers check no longer passes on a missing folder.
- **Paper Plane:** none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-18 (lead-33) | acb7d04..4582246 | 6 merged + 1 lead commit; 13 filed | 829: round 2; 1 gate flake | 2216 passed, 0 failed | 0.0.91 boot OK; vm-play-check 12/25 (SELinux) |
| 2026-11-18 (lead-34) | 4582246..486cc14 | 4 merged + 2 lead commits | 834, 840, 852: round 2 (all real) | 2216 passed, 0 failed | 0.0.92: vm-play-check 20/12 (SELinux, fixed by ADR-036) |
| 2026-11-18 (lead-35) | 486cc14..HEAD | 7 tickets merged in 5 branches (866 lead) + 2 lead docs commits; filed 866-875 | 866, 853, 856: round 2 (866: VM script bug; 853: stale spec, shot order; 856: focus order); 1 lead review fix | 2247 passed, 0 failed (last gate) | 0.0.93: helper PASS, check 29/7 (staging.io, fixed by 866); 0.0.94: check 33/2 (installs work; RUY-876, 877 filed) |
