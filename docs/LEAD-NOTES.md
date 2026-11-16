# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-25 (Opus, 2026-11-15/16, a planning session: no dispatch on the owner's word)

- **Review range:** 0874b65b..HEAD: lead docs commits only (432d4984, 4fe1cf59, a168a78e, de7e3a67 and this handoff); no builder code merged. Paper Plane `changes` cursor 4132.
- **Paper Plane 0.17.1:** all 13 of our issues closed. Done here: the `owner:lead` label is **lead-only** (`claim_roles: [lead]`, PATCH `/api/projects/RUY/labels/owner:lead`), so ready lead tickets sit in Ready; ordering is `update sort_order=` (LEAD.md, PLANNING.md, CLAUDE.md updated). 8 written lead tickets moved to Ready (407, 449, 490, 498, 507, 508, 519, 543); 14 more were refused for no acceptance criteria and stay in Backlog. Filed EnigmaNL/PaperPlane#14 (Ready count per role) and #15 (`list` in queue order).
- **Architect role (owner, 2026-11-16):** `.claude/agents/ruya-architect.md`, LEAD.md 5b: Opus, read-only, lead-triggered **every 5-6 lead sessions** (the owner lowered it from 3-4), before a phase or release, or for a structural question; its Accepted (architect) ADRs are committed verbatim. **None run yet.**
- **Owner's Dell finding:** the notification centre is always empty because nothing serves `Notifications1` (the shell half was built against the mock; `DBusNotificationsBackend::post` drops silently). Filed **RUY-730**; RUY-88 keeps the app side and waits on it.
- **Formations closed:** RUY-557, RUY-564.

## New owner requests planned this session (all reviewed against main, none dispatched)

| Formation / ticket | What | State |
|---|---|---|
| RUY-730 | ruya-notifications service (per-profile history, settings) | Ready, builder |
| RUY-736 | Closing screen: Force quit after 5 s; STOP_GRACE 30 s backstop; fix the scope kill (Dell journal: ACBR, SeriousSam) | Ready, builder |
| RUY-737 | Device health: drive SMART via udisks2; load `drivetemp` (the Dell's SATA SSD has no temperature) | Ready, builder |
| RUY-738 | Overlay: 1% / 0.1% low FPS, rolling 60 s | Ready, builder |
| RUY-743 | Like pads named "X", "X 2" on connected surfaces | Ready, builder |
| RUY-744 | App permissions (Flatpak overrides: network, devices keeping input, broad files), split from RUY-80 | Ready, builder |
| RUY-735 Power profiles | 731 spike+ADR (lead, Ready); 732 service, 733 Hub/Settings row, 734 the machine's battery | 732-734 wait on 731; RUY-528 must not ship its fixed EPP line |
| RUY-742 Keyboard v2 | 739 canvas (lead, Ready); 740 more pad buttons as keys (after RUY-475); 741 rebuilt TextEntry | design first |
| RUY-748 Captures | 745 screenshots (Session1.StoreCapture), 746 the capture button (after 745), 747 recording spike (lead, Dell; codec licences may be an owner question) | 745, 746, 747 Ready; RUY-142 keeps library and app access (phase 5) |
| RUY-749/750 Hub pinned panels | design + ADR-033 amendment (lead, Ready), then the build; pinned panels hold their **controls**, not readings (owner correction) | design first |

## First thing next session
1. **Dispatch** (owner held it all of lead-25): the lanes reviewed in lead-25: **RUY-730** first (fixes the owner's Dell), RUY-530+531 (one builder), RUY-523, RUY-549 (needs WSL: no chain beside it). Then RUY-736, 737, 738, 743. Don't run RUY-740 and RUY-746 in parallel (both in ruya-inputd's router).
2. **Board fixes found:** RUY-476 looks like a duplicate of RUY-689; RUY-634 is Ready but part of it (`compatible`, `min_api_level`) is on main: re-scope or close.
3. Triage inbox RUY-720..728 (no area labels yet). RUY-718 (bell hard to reach) after RUY-730.
4. **Image 0.0.88** once code lands: owes RUY-616's busrecv and signals checks and RUY-716's profiles check.
5. **First architect audit** at a natural stop: general, focus on mock-only drift and a check that refuses a "built" spec claim whose contract is in `NOT_SERVED`.
6. Lead design work waiting: canvases for RUY-739 (keyboard) and RUY-749 (pinned panels); RUY-731 (power ADR) and RUY-747 (recording) spikes on the Dell.

## Concerns (ranked)
1. Mock-only drift: the notification centre looked built for five lead sessions; the owner found it. The architect audit and a lint are the answer.
2. The wake flow is still unproven on hardware (RUY-707; the Dell has it since 0.0.87); co-op on real hardware not tried (RUY-681).
3. Stuck `python3 -` processes (RUY-727) still need the owner.
4. Ready grew by about 20 tickets this session: order them (`sort_order`) before the next dispatch round.

## Process changes in lead-25
- Lead-only label instead of "lead tickets stay in Backlog" (Paper Plane rule, docs updated); `update sort_order=` instead of REST PATCH.
- The architect role (LEAD.md 5b, agent file, budgets row, authority line).
- Lesson: a mechanical "has acceptance criteria" check must read the description, not the comments (my dry run counted 22, the server accepted 8).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-15 (lead-24) | f5e0726..0874b65 | 5 merged, 10 filed | rounds 2 for 2; 1 spec gap closed; 9 filed | 1977 QML + 166 skips | 0.0.87 queue 28/28; Dell on 0.0.87 |
| 2026-11-16 (lead-25) | 0874b65..HEAD | 0 merged (owner held dispatch); 22 tickets written from owner requests | 1 owner-found gap (RUY-730); 2 board problems found; 2 PP issues filed | docs only (`dev.ps1 docs` green) | none |
