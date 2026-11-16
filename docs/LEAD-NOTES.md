# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-28 (Opus, 2026-11-16; owner: "finish for tonight, we continue tomorrow")

- **Review range:** 70292d68..HEAD.
- **Merged:**
  - RUY-548 (Options menu line boxes, `Theme.lineFactor`): reviewer APPROVE, design review clean, gate 2089 passed / 0 failed.
  - RUY-91, the `.play` spike (lead).
- **Paper Plane:** `changes` cursor **4427**. Formations RUY-555 (CI green) and RUY-556 (game page) are closed.
- **The `.play` spike (RUY-91), owner request.** Run by an Opus agent on the Dell; answers in 05 §6.3, §6.4, §7.1, §16 and §18, ADR-014 "Spike result", and an ADR-025 note. Raw results: `scripts/spikes/play/RESULTS.md`.
  - The Flatpak import route works (no bubblewrap fallback).
  - Windows display in v1 is X11 through xwayland-satellite.
  - GE-Proton runs directly, without umu and the Steam Linux Runtime: the Flatpak 1.18.4 portal's `--usr-path` is broken.
  - Filed: RUY-776 (portal, **high**: it may break Proton in the Steam Flatpak), RUY-777 (Wine games ignore SIGTERM, 31.5 s stop), RUY-778 (compositor protocol versions), RUY-779 (no memory limits on game units).
  - Comments on RUY-92, 100, 101; RUY-32 narrowed.
  - RUY-90 (epic) was released by the owner after the spike (see "Owner direction").
- **Dell:** the sleep block for the spike is removed (suspend works again). It still runs 0.0.89. Left on it: Flathub Wine 11 and the Sdk 25.08, and `/var/tmp/ruy91` (2.2 GB), which can go.

## In flight at the handoff
1. **RUY-501** (stick editor detail lines): the builder's HANDOFF is done (d716f231 in `D:\dev\RuyaOS-worktrees\RUY-501`, test 2090 passed, shots EN/TR at 1080p and 720p, revert CAUGHT); the ticket is In Review. Next lead:
   - read its Outcome on the ticket;
   - dispatch `ruya-reviewer` and `ruya-design-reviewer` (new copy, EN and TR);
   - merge, gate, remove the worktree.
2. **Image 0.0.90** (`image-chain.sh 0.0.90 oci`, from 70292d68, started 22:3x): still building after about 70 min, so the second build in a row did **not** hit the cache the way RUY-771 expects. Read `output/chain/summary.txt` and `build.log` ("Using cache" lines), and put both times on RUY-771 (0.0.89: 29 min). It does not contain RUY-548, RUY-91 or RUY-501.
3. **Push refused at the end of lead-28:** `push-main.ps1` said "dev.ps1 test is not ALL GREEN". The merge gate on the same code (RUY-548) was green with 2089 passed, and the image build ran alongside (load). A re-run while the image build was still going was ALL GREEN (2089 passed, 0 failed; the VM check lint took 199 s under load). So the refusal was a load flake in the host tests: which check failed was not kept, because the log tail cut it. If it recurs, keep the full push log. A second push followed: if `git status -sb` says ahead, it failed too. Check that RUY-548's Fedora CI run happened (`output/last-green-linux.txt`).

## Owner direction (2026-11-17): the next sessions are all about `.play`
The owner answered four questions at the end of lead-28:
- **Foundations first**, in the epic's order. The epic RUY-90 is released (Done); the goal is formation **RUY-780**.
- **Two lanes at a time.**
- **Q7:** an installed package is system-wide, with data per profile (05 §16).
- **Order:** finish the half-done non-.play work below, then only `.play`.

## First thing next session
1. Finish the in-flight items above:
   - RUY-501: review and merge;
   - the failed push (see 3 above);
   - image 0.0.90: RUY-771's times, then the VM queue on RUY-390 (RUY-770 `vm-session-check.sh kill`), then `scripts/dell-update.sh 0.0.90`.
2. **RUY-776:** install Steam on the Dell and run a Proton game. Windows `.play` games depend on the same Flatpak portal.
3. **Then `.play` only.** Review each child ticket against main and the spike comments ("Lead review before the build"), and fix the stale "Wine is the only system runner" wording (ADR-025) in each one you touch.
   - First lanes, host-verifiable and in different crates: **RUY-92** (format crate and schema; its run.env comment) and **RUY-94** (art and video vetting).
   - Next: RUY-93 (signing, lead), RUY-95 (`ruya-pack`), RUY-96 (`Play1` contract, mock, client), RUY-99 (importer core).
   - Check the blockers (`formation ref=RUY-780` showed 12 blocked) and set the order with `sort_order`.
   - RUY-97 (design step) needs a Claude Design canvas before RUY-98 (the shell).
4. **Parked while `.play` runs:** RUY-773, 761, 17, 744, 526, RUY-12's re-plan, inbox triage (RUY-666..779), the architect audit, and the owner's hands-on checks RUY-766, 736, 743 and 738.

## Concerns (ranked)
1. **Weekly plan at 72 %** (resets 2026-11-20 18:00). One lane only; the spike ran on the owner's request despite the "no spikes" row.
2. **Flatpak 1.18.4's portal** (RUY-776) may break Steam's Proton on the image. Unchecked.
3. **The image build cache** (RUY-771) did not hold for the second build in a row.
4. VM fakes too lenient (lead-26, architect topic).

## Process changes in lead-28
- Lead: I didn't start with the owner's "next" item (the spike) and went into the routine loop first. Rule kept: a handoff's owner request comes before the build loop (already in "First thing"; no new text).
- Dell: a runtime sleep block (`systemctl mask --runtime` on the sleep targets plus a `systemd-inhibit` unit) keeps it awake during agent runs; both end at a reboot.
- Paper Plane: none.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-16 (lead-26) | 8864330..86dab5a | 11 merged; 5 filed (764, 765, 766, 770, 771) | second rounds on 743 (3 rounds) and 524; 2 spec gaps closed; 2 VM-check bugs fixed | 2051 passed, 0 failed (RUY-524 gate) | 0.0.88 queue: all but RUY-770 and sample; Dell on 0.0.88 |
| 2026-11-16 (lead-27) | 86dab5a..70292d6 | 6 merged + 1 lead fix (765); 2 filed (772, 773) | round 2 on 771, 532, 533, 534; 2 owner UI fixes; 3 spec gaps closed; 2 PP issues | 2077 passed, 0 failed (RUY-533 gate) | Dell on 0.0.88 checks; 0.0.89 built, Dell updated |
| 2026-11-16 (lead-28) | 70292d6..HEAD | 1 merged (548) + the `.play` spike (91); 4 filed (776-779) | none on 548 (both reviews clean) | 2089 passed, 0 failed (RUY-548 gate) | spike on the Dell (hw); 0.0.90 building |
