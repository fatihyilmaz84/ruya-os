# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-30 (Opus, 2026-11-17)

- **Review range:** e4df6f63..HEAD. **Paper Plane `changes` cursor:** run `changes` with no cursor at the start; lead-30 ended past 4616.
- **Merged or committed (5):**
  - RUY-801 (lead; Steam in X11 mode and Big Picture). Two image files, `x11-apps` and `app-args`, plus per-app launch arguments in ruya-session.
  - RUY-97 (lead; the design). Canvas "RuyaOS Play Packages" https://claude.ai/artifact/SSS7j1ShDEvknxwiv1xsSj and 04 §5.4 (every number and string). `pause` added to the icon subset.
  - RUY-802 (builder; the .play components). Two rounds; trust badges are always `solid` (lead decision, for contrast).
  - RUY-98 (builder; Install from USB). One round. Code, design and UX reviews all clean. Play1 gained the developer-mode calls.
  - The lead's review docs fix: 05 §7.2, 04 §5.4 and 02 Settings now say a Standard profile always enters an admin's PIN.
- **The Dell, by hand:**
  - A usroverlay holds `/usr/share/ruyaos/x11-apps` and a `/usr/local/bin/flatpak` wrapper that adds `-gamepadui`. Both are gone at reboot.
  - Profile p1 is signed in to Steam (the owner) and opens in Big Picture.
  - The steam-wrapper stamp for p1 is set (RUY-800).
- **The owner on the Wii U Pro in Steam:** "B selects, A is back". This is by design (games get positional buttons, 06 §11.2). The fix is Settings > Controllers > the pad > Button layout in games > Nintendo layout. Whether Nintendo pads should default to that in Steam is an open owner question.

## Owner direction (still in force)
- `.play` only, foundations first (formation **RUY-780**). The weekly plan is at **82 %** (resets 2026-11-20 18:00): **one lane**.
- RUY-798: the owner's `burnout3-ruya-native` is the native `.play` test game, after RUY-100 and RUY-101.

## First thing next session
1. **Image 0.0.91** (`image-chain.sh`): the VM queue (RUY-390) has RUY-801's check, "Steam in Big Picture on the Dell with no overlay". Update the Dell. The Dell's overlay goes at that reboot.
2. **RUY-100** (lead, VM): the `ruya-play` service. Its comments list the inputs. Also fold in RUY-805 (per-permission reasons and the revocation reason in Inspect) and the developer-mode calls RUY-98 drafted (`Get/SetDeveloperMode`; the trust store already has `set_developer_mode`). Then RUY-101 and RUY-102.
3. **RUY-809** (builder, high): Install from USB follow-ups (the result after leaving the page, Back-only hints, a revoked installed game, hiding the entry without ruya-play, "kumanda" to "kontrolcü").
4. **Owner-pending:**
   - RUY-786: the sleep test;
   - RUY-776: a free Proton game on the Dell, now possible (Steam is signed in);
   - the Nintendo-layout default question above.
5. **Parked:**
   - inbox RUY-799 to RUY-811 to triage: RUY-800 (steam-devices warning), 803 (first-seen date), 804 (Turkish dotted-I caps), 805, 806, 807 (translucent badge contrast), 808, 810 (tier on cards), 811;
   - the architect audit (due);
   - RUY-773, 761, 17, 744, 526;
   - a stale worktree `.claude/worktrees/ruy-4-options-menu-design-af91a0` (not this session's; look before removing).

## Concerns (ranked)
1. **RUY-786:** after sleep and wake the pad did not move LibreQuake. Not reproduced. Leads are in lead-29's notes: the reconnect hop, and `routing.rs` `mask_held`/`bind`.
2. **The weekly plan at 82 %.**
3. **The `.play` Linux paths** have run only in WSL `cargo test` and on the mock. RUY-100's `vm-play-check.sh` is the first real run.
4. **Flaky tests under load:** RUY-794, RUY-784.
5. **Instruction budgets:** root `CLAUDE.md` 11.3 KB (budget about 10) and `shell/CLAUDE.md` 8.0 KB (about 7). Prune next session.

## Process changes in lead-30
- **Tests:** `dev.ps1 shots` writes `review\SHOTS-AT.txt` (the commit, plus "+ uncommitted changes" when the tree was dirty). The builder's and reviewer's check lines name it. Shots older than the last commit were reviewed twice this session (RUY-802 round 1, RUY-98's progress shot).
- **Lead:** the design step worked as follows:
  - an Explore subagent gathered the spec, contract and component facts (about 140k tokens, outside the lead's context);
  - one parameterised `Main.dc.html` plus thin boards, published several per call;
  - the numbers written into 04 rather than the ticket;
  - the build split into a builder ticket.
  A lead design session costs about 60k tokens of the lead's own context.
- **Builders:** RUY-98 took 386k tokens in one round (over the 300k mark) for five screens plus a contract change. Write page-flow tickets of that size as two tickets.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-16 (lead-28) | 70292d6..9392257 | 1 merged (548) + the `.play` spike (91); 4 filed (776-779) | none on 548 (both reviews clean) | 2089 passed, 0 failed (RUY-548 gate) | spike on the Dell (hw); 0.0.90 building |
| 2026-11-17 (lead-29) | 9392257..e4df6f6 | 7 merged (501, 92, 94, 96, 93, 95, 99); 16 filed (784-799) | 2-3 review rounds on each .play crate; 5 lead fixes; bubblewrap#835 | 2106 passed, 0 failed (RUY-99 gate) | 0.0.90: 17/18 + kill PASS; Dell on 0.0.90 |
| 2026-11-17 (lead-30) | e4df6f6..HEAD | 2 lead (801, 97) + 2 merged (802, 98); 12 filed (800, 803-811) | 802: one round 2 (solid badges, TR label, held keys); 98: clean, 3 doc fixes by the lead | 2191 passed, 0 failed (RUY-98 gate) | Dell: Steam fixed by hand (hw); no image |
