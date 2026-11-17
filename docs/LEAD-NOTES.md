# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-29 (Opus, 2026-11-17)

- **Review range:** 93922571..HEAD. **Paper Plane `changes` cursor 4609.**
- **Merged (7):**
  - RUY-501 (stick details);
  - the `.play` foundations: RUY-92 (format crate), RUY-94 (art vetting), RUY-96 (Play1 contract, mock, client), RUY-93 (signing, trust), RUY-95 (`ruya-pack`), RUY-99 (importer core).
  - Every `.play` crate took 2 or 3 review rounds, and each round 1 found real security holes. A lead review comment before the build is on every ticket.
- **Lead fixes:**
  - `image/Containerfile` declares `RUYA_VERSION` at its first use (RUY-771): the package layers missed the cache on every version.
  - `push-main.ps1` pushes the tested commit, not the `main` ref.
  - Play1 key ids are 32 hex characters.
  - Spec wording fixes in 02 and 05.
- **Image 0.0.90:**
  - VM queue: 17 of 18 passed, and RUY-770 `kill` passed. `vm-session-check` failed twice under load and passed alone, filed as RUY-784.
  - The Dell is on 0.0.90 (rollback 0.0.89). Its idle GPU was not measured (someone was using it).
- **Dell:** the Steam Flatpak and runtimes are installed (RUY-776; about 16 GB, plus `/var/tmp/slr` 1 GB). There is a usroverlay with strace and gdb (gone at reboot). Diagnostic files are in `/root/diag-*`.
- **Upstream:** filed containers/bubblewrap#835 (owner's yes): the portal's `--usr-path` fd bug.

## Owner direction (2026-11-17, still in force)
- `.play` only, foundations first, two lanes (formation **RUY-780**: 7/17 done). Q7: a package is system-wide, with data per profile.
- The weekly plan was at **80 %** at the handoff (resets 2026-11-20 18:00), past the 70 % row. **Run one lane**; tell the owner.
- **RUY-798:** the owner's `burnout3-ruya-native` (a separate repo; its code is developed there) is the real native `.play` test game, after RUY-100/101. The owner's PS2 data never enters RuyaOS repos, images or CI.

## First thing next session
1. **RUY-97, the design step** (lead): a Claude Design canvas for the package page and the install flow (`LEAD.md` 5, "Design first"). It must exist before RUY-98 (the shell's Install from USB, now unblocked by RUY-96).
2. **RUY-100**, the `ruya-play` service in the image: lead, VM. Its comments list the inputs from RUY-96 and RUY-99:
   - uid check for `admin_approved`;
   - reconcile at start;
   - surface `state/journal`;
   - Play1 off `NOT_SERVED`;
   - helper memory above 1.25 GiB;
   - store-blocklist file (RUY-796).

   Then RUY-101 (launcher; its comment has the `resolve()` contract) and RUY-102 (permissions).
3. Review each ticket against main before the build. Fix the stale "Wine is the only system runner" wording (ADR-025) where it remains.
4. **Owner-pending:**
   - RUY-786: the hands-on sleep test, "later";
   - RUY-776: a Steam login on the Dell for a real Proton game.
5. Parked: RUY-773, 761, 17, 744, 526, RUY-12's re-plan, inbox triage (now up to RUY-799), the architect audit (due), and the owner's hands-on checks RUY-766, 736, 743 and 738.

## Concerns (ranked)
1. **RUY-786:** after sleep and wake, LibreQuake was not controllable (owner: "nothing moved at all"). Not reproduced. Leads: the hop from the physical pad to evdev after reconnect (the wiimote driver's node), and the input masks at rebind (`routing.rs` `mask_held`, `bind`). RUY-785 (rumble lost on reconnect) is confirmed and separate.
2. **The weekly plan at 80 %.**
3. **The `.play` Linux paths have run only in WSL `cargo test`** (ruya-play's openat code), not in an image. RUY-100's `vm-play-check.sh` is the first real run.
4. Flaky tests under parallel load: RUY-794 (`tst_player_chips`), RUY-784 (`vm-session-check`).

## Process changes in lead-29
- **Scripts:** `push-main.ps1` pushes the commit it tested (`$head:refs/heads/main`). It used to push the `main` ref at its end, so a merge made during its 7-minute Linux CI job could have gone out untested. The lead aborted such a merge this session.
- **Lead:** for security-critical crates, run the code reviewer and the API reviewer in parallel and send one combined round-2 list. It worked every time. A small delta round (RUY-94 r3, RUY-99 r2) can be verified by the lead directly: read the diff, run the tests, record the approve.
- **Tests:** the Unix-only `cargo test` paths can run in WSL before a merge: `CARGO_TARGET_DIR=/root/tgt-x cargo test -p <crate> --locked` from `/mnt/d/...`. From Git Bash, call `wsl.exe` with `MSYS_NO_PATHCONV=1`, or the script path is mangled.
- **Paper Plane:** the MCP servers timed out at session start ("version negotiation probe"), then connected on retry. Not filed.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-16 (lead-27) | 86dab5a..70292d6 | 6 merged + 1 lead fix (765); 2 filed (772, 773) | round 2 on 771, 532, 533, 534; 2 owner UI fixes; 3 spec gaps closed; 2 PP issues | 2077 passed, 0 failed (RUY-533 gate) | Dell on 0.0.88 checks; 0.0.89 built, Dell updated |
| 2026-11-16 (lead-28) | 70292d6..9392257 | 1 merged (548) + the `.play` spike (91); 4 filed (776-779) | none on 548 (both reviews clean) | 2089 passed, 0 failed (RUY-548 gate) | spike on the Dell (hw); 0.0.90 building |
| 2026-11-17 (lead-29) | 9392257..HEAD | 7 merged (501, 92, 94, 96, 93, 95, 99); 16 filed (784-799) | 2-3 review rounds on each .play crate (zip overflow, iCCP bomb, rotation splice, blocklist downgrade, key echo, record-before-commit); 5 lead fixes; bubblewrap#835 | 2106 passed, 0 failed (RUY-99 gate) | 0.0.90: 17/18 + kill PASS; Dell on 0.0.90 |
