# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-27 (Opus, 2026-11-16)

- **Review range:** 86dab5aa..HEAD. 6 merges, all reviewed and gated: RUY-770, 771, 528, 532, 533, 534 (the game page now has all four parts). Lead commits: 472bb8da (RUY-765 revert-check paths), 9fcc51a4 (04 Activity summary), c371ec97 (Play/Install ring clipped, owner), 5c4ef46c + 1cdc349c (hint shade, owner). Paper Plane `changes` cursor **4298** at the start (read it again next time).
- **Owner requests this session:**
  - The focus ring of Play/Install was clipped at the left. Fixed: the game page viewport now spans the screen width (`sideBleed`).
  - The hard edge behind the hints is now a soft **hint shade**: `Shell.qml` `hintShade`, token `hintShadeMid`, 04 "Pages". It is opaque from the hint bar's top down.
  - Run the **`.play` spike next**: RUY-91 is Ready (lead, `dell`), and RUY-90 records the unpark. The owner may start it in a new session.
- **Image 0.0.89** (13a8af72, image 157d755d6ae4). The chain took 29 + 32 + 14 min; the build hit the cache (0.0.88 took 79 min). Dell update: see "First thing" 1. RUY-534 merged after the build, so it is **not** in 0.0.89.
- **Dell results on 0.0.88** are on the tickets and on RUY-390:
  - pass: RUY-530 (Resume median 203 ms), RUY-737, RUY-730 (D-Bus side);
  - RUY-531: fio is not in the image, not run;
  - RUY-738: the overlay lows need a person at the screen.
- **RUY-528 numbers:** EPP `performance` gives no FPS gain in SuperTuxKart and costs about 0.5 W at idle. They are on RUY-731; nothing ships.
- **Paper Plane 0.19.0:** the plugin is updated (it applies from the next session). The standalone CLI was updated from 2.0.30 to 2.1.311 (`~/.local/bin` is not in the user PATH; the owner was told). Usage health `ok`. Issues filed: EnigmaNL/PaperPlane#16 (ECONNRESET), #17 (connect status ignores per-role entries).

## First thing next session
1. **Dell on 0.0.89** (done in lead-27: booted 0.0.89, rollback 0.0.88, shell up; degraded = RUY-24 only). Run the VM queue on RUY-390: RUY-770 `vm-session-check.sh kill`. RUY-771: the **next** chain is the second build in a row; it must hit the cache, and both times go on RUY-771 (this one: 29 min).
2. **RUY-773** (lead, design): the game page content top is 276.5, not 258. The Your activity block overflows the first screen; the badges slide under the title while it has focus.
3. **Inbox from this session** (filed): RUY-772 (STK cold-start stall), RUY-774 (viewer failed box and cross-fade, design), RUY-775 (mock Store text setters).
4. **Still open from lead-26:**
   - RUY-761 (Options menu spec and design) and RUY-17;
   - the first architect audit (5b);
   - RUY-744; RUY-526;
   - triage of inbox RUY-720..728; ordering of Ready; RUY-731/747 spikes;
   - RUY-12 needs a re-plan (compositor; see its comment).
5. Owner hands-on checks still pending: RUY-766, 736, 743, and RUY-738's overlay.

## Concerns (ranked)
1. **Weekly budget at 70 %** (resets 2026-11-20 18:00). The owner asked for two lanes; LEAD.md says one at 70 %.
2. **Lost builder handbacks:** twice this session (RUY-771 r2, RUY-534 r2). The worktree-commit plus green-marker check worked both times.
3. **Shared game-page file:** three lanes edited `AppDetailPage.qml` at once. It went well, because each builder kept to a slot, a flag and the stop order, and merged main itself.
4. VM fakes too lenient (lead-26, architect topic); load flakes (none this session).

## Process changes in lead-27
- `revert-check.ps1` refuses a file from another checkout and never creates a file (RUY-765); dev.ps1 self-check.
- Parallel lanes in one QML page: tell each builder its touchpoints (slot, flag, stop order) and have it merge main before review.
- Paper Plane: none beyond the two issues.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-16 (lead-25) | 0874b65..8864330 | 0 merged (owner held dispatch); 22 tickets written from owner requests | 1 owner-found gap (RUY-730); 2 board problems found; 2 PP issues filed | docs only (`dev.ps1 docs` green) | none |
| 2026-11-16 (lead-26) | 8864330..86dab5a | 11 merged; 5 filed (764, 765, 766, 770, 771) | second rounds on 743 (3 rounds) and 524; 2 spec gaps closed; 2 VM-check bugs fixed | 2051 passed, 0 failed (RUY-524 gate) | 0.0.88 queue: all but RUY-770 and sample; Dell on 0.0.88 |
| 2026-11-16 (lead-27) | 86dab5a..HEAD | 6 merged + 1 lead fix (765); 2 filed (772, 773) | round 2 on 771, 532, 533, 534; 2 owner UI fixes; 3 spec gaps closed; 2 PP issues | 2077 passed, 0 failed (RUY-533 gate) | Dell on 0.0.88 checks; 0.0.89 built, Dell updated |
