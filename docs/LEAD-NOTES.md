# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-30 (Opus, 2026-11-17)

- **Review range:** e4df6f63..HEAD. **Paper Plane `changes` cursor:** run `changes` with no cursor at the start; lead-30 ended past 4616.
- **Later in the session:**
  - RUY-801 was reviewed and is Done; the image check stays on RUY-390. Its review fix, 18c87e03, makes a malformed x11 helper argv exit 2.
  - RUY-809 merged (Install from USB follow-ups).
  - A flaky RUY-98 test was fixed (ec95e753; the push gate had refused once).
  - The owner skipped the image ("skip the new image if you don't need it").
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
1. **Steam on the Dell** (RUY-776, owner, lead-30). BioShock (7670, the 2007 edition, no pad support) runs under Proton, and keyboard and mouse reach it. The pad can't drive it for three reasons:
   - Steam takes the game window under xwayland-satellite for "the desktop" (RUY-812);
   - Steam Input needs uinput (RUY-800/44);
   - the game sits outside the tracked scopes (RUY-813).
   The pad is also recreated on focus changes (RUY-814). **RUY-813 and RUY-814 come before RUY-100**: they hit every Steam game.
2. **RUY-815** (owner request, epic): Steam games as first-class apps (Library, launch, Hub name, pause and close; Steam itself too). It needs the architect first: should Steam run on xwayland-satellite or on nested gamescope (spec 03 planned gamescope)? Run the architect audit (due) with RUY-812 and RUY-815 as the focus questions.
3. **RUY-100** (lead, VM): the `ruya-play` service. Fold in RUY-805, the developer-mode calls RUY-98 drafted, and `Play1.Remove` (RUY-816 item 3). Then RUY-101 and RUY-102.
4. **The image:** when one is needed, the VM queue has RUY-801's check (Steam in Big Picture with no overlay). Until then the Dell needs the usroverlay by hand after each reboot (`x11-apps` plus the `-gamepadui` wrapper; recipe in RUY-801 and RUY-776).
4. **Owner-pending:**
   - RUY-786: the sleep test;
   - RUY-776: a free Proton game on the Dell, now possible (Steam is signed in);
   - the Nintendo-layout default question above.
5. **Parked:**
   - inbox to triage: RUY-799, 800 (steam-devices warning), 803 (first-seen date), 804 (Turkish dotted-I caps), 805, 806, 807 (translucent badge contrast), 808, 810 (tier on cards), 811, 812-816;
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
| 2026-11-17 (lead-30) | e4df6f6..HEAD | 2 lead (801, 97) + 3 merged (802, 98, 809); 17 filed (800, 803-816) | 802: one round 2 (solid badges, TR label, held keys); 98 and 809 clean; 801 review fix; a flaky 98 test fixed | 2198 passed, 0 failed (RUY-809 gate) | Dell: Steam by hand, BioShock under Proton (hw); no image |
