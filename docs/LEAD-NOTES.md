# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Lanes at handoff (2026-11-06)

None running: every worktree is merged and removed (`git worktree list` shows only the main checkout). **Owner, 2026-11-06: no new tasks are created or dispatched until the owner says so.** T-189..T-194 exist as `todo` (planned before that instruction) and must not be dispatched without the owner's word.

## Review range

- **Last reviewed commit: the handoff commit of this session** (everything since `4c0e713` was merged only after a `ruya-reviewer` verdict, except T-187, whose small diff the lead read itself; the lead also checked the round 2 of T-182, T-183, T-188, T-184 and T-186 diffs itself).
- **Last VM verification: image `0.0.42-lead` of main at `c98a9d1`** (smoke `RUYA_BOOT_OK`, devices 57 PASS with `-Audio`, store 67, library, storage 98: all PASS). Docs-only commits followed. Nothing in the range is unverified in the VM except the Linux-only unit test `moving_the_active_link_changes_the_fingerprint` (`#[cfg(unix)]`, never run on Windows).

## Concerns (ranked)

1. **Critical path is still T-162 -> T-164 -> T-165/T-147** (`[lead]`, `ruya-session` in the image). Not started; the image lane is free. Without it no app can be launched from the shell, so the MVP slice is blocked. Hard lead work with VM debugging: keep a whole session for it.
2. **Tests that cannot fail** came up again (T-184: `wait(NaN)`; earlier T-167, T-176). Every reviewer caught it, the builders did not. T-189 (a gate check) is planned and undispatched; PLANNING.md Lessons has the rule meanwhile.
3. **Owner scope decisions this session** (recorded in STATUS and the specs): media and streaming apps (Plex, Steam Link and the like) are separate Store apps, out of the first MVP; Steam (Proton) and RetroArch are separate apps too (owner, 2026-11-06, answered at the end of the session); blur and shadows stay the default look on capable hardware, tiers are the fallback (04 principle 5; the shadow tokens are planned, none built); design pass wanted (Store home, backdrop, card art) but **no tasks written**: the owner asked for no new tasks. Findings from the screenshots are in the session transcript only: Store cards are placeholder tiles, Store and profile backdrops use hard-edged circles while Home has a smooth tinted gradient, Store home is list-like, focus has no depth.
4. **Hardware (B-002):** the ISO now boots to the shell in QEMU (T-178); the Dell is the next real test. Wi-Fi under the new NetworkManager deny rule (T-180) is verified only by `pkcheck` as the service's pid.
5. **STATUS is ~14 KB** (budget ~10 KB): the Open owner decisions and the "Decided" paragraph are long; prune when planning resumes.
6. Older, unchanged: compositor gaps (B-003, suspend T-166), high-risk gate enforced by the shell only, `caller_is_admin` copied in two services, stale canvas boards (Settings), Turkish wording review (owner).

## Host facts learned this session

- `vm-devices-check.sh` fails five audio lines ("no default sink", volume does not follow) on a VM booted without a sound card: boot with `smoke-test.ps1 -Keep -Audio` (the devices check needs it; the others don't).
- An `ssh ... bash vm-library-check.sh` may not return after the script prints `ALL CHECKS PASSED` (a leftover background monitor holds the session); read `/root/library-check.log` from a second ssh instead of waiting.
- `git worktree remove` can fail with "Directory not empty" (files from builds, `NUL`): `rm -rf` the folder from Git Bash, then `git worktree prune`.
- A fresh worktree rebuilds the image stages from scratch (30+ min); `make-disk.sh` can fail "Cannot allocate memory" if `dev.ps1 test` runs in parallel: never overlap an image build with a test run.
- `dev.ps1` run from the main checkout tests main's tree, not a worktree's: builders must `Set-Location` into theirs (now in `ruya-builder.md`).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-04 | 9b77857..b4733f4 | T-155, T-157, T-159 (+ T-130 fresh read) | 0 / 7 tasks planned (T-162..T-168). Process: builder/reviewer agents, worktree lanes, lead-only STATUS, VM queue, `free-space.ps1`, shots lock (owner) | 271 + 22 skipped QML, 242 Rust | not run |
| 2026-11-04 | 2c134ce..handoff | 12 merged: T-167, T-168, T-136, T-158, T-137, T-169, T-163, T-160, T-171, T-172, T-170, T-144 | 6 CHANGES_REQUESTED, 3 lead fixes | 327 + 28 skipped QML | `0.0.32`/`0.0.33` ok |
| 2026-11-04 (late) | handoff..223d7ed | +7: T-175, T-176, T-161, T-173, T-145, T-177, T-174 (19 in the session) | 10 CHANGES_REQUESTED in the session; lead fixes: T-173 stop_scan, T-176 shots log, scratch known_hosts | 346 + 28 skipped QML | lead `0.0.37` ok |
| 2026-11-05 | 4c0e713..handoff | 11 merged: T-178, T-179, T-180, T-181, T-182, T-183, T-184, T-185, T-186, T-187, T-188 | 6 CHANGES_REQUESTED (a real regression in T-182 `InstalledChanged`, a vacuous test in T-184, a VM check that could not pass in T-183 and T-188, a design miss in T-185 that I decided and fixed); 6 tasks planned (T-189..T-194), not dispatched. Process: builders run dev.ps1 in their worktree; PLANNING lessons (VM JSON, tests that cannot fail); image/CLAUDE VM quirks | 381 + 30 skipped QML | lead `0.0.42` ok: smoke, devices 57, store 67, library, storage 98 |

Older rows: git history of this file.
