# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; up to four lanes; builders run nothing in WSL since lead-20**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-26 (Opus, 2026-11-16)

- **Review range:** 88643302..HEAD. 11 merges, all reviewed and gated: RUY-530+531, 549, 523, 730, 738, 736, 737, 743, 766, 524. Lead commits: b444a9e3 (gaming check: NVMe), f9a9b9a4, 7f417f4b (notifications store fsync), a36bdb8a (tst_profile_admin fix), d9f4fc09, 335dc52f (04 §5 empty states), f759c5fc (VM check fixes) and this handoff. Paper Plane `changes` cursor **4297**.
- **Image 0.0.88** (15bb9ba5, image 0e57bfd9764d) is built, and the Dell runs it (rollback 0.0.87). VM queue results are on RUY-390: everything passes except
  - **RUY-770:** the 30 s backstop's AppExited says `quit` (status 15), not `killed`;
  - **sample check:** not run (hello-repo.tgz is staged by hand; unverified).
  - `vm-session-check.sh check` was not rerun after the flatpak fix.
- **The Dell's "degraded" state** is only bootloader-update.service: Secure Boot is on and the firmware has no MS UEFI CA 2023 (RUY-24).
- **The chain took about 2 h** because `free-space-wsl.sh` prunes podman's layer cache: **RUY-771**.
- **Owner decision (2026-11-16), Options menu:**
  - one action: A does it;
  - several actions with no main one: A opens the menu;
  - holding A or the options button always opens the menu.

  Recorded as RUY-761 (lead): spec it in 02 §1.7 and 04 §5, a Claude Design board for Bluetooth, then audit the list screens. RUY-17 waits on it.
- **The owner waived the UX review** for screens designed in Claude Design (RUY-524). The design-spec review still runs, as a conformance check.

## First thing next session
1. **Dell checks for 0.0.88.** The lead has full SSH (owner, 2026-11-16). Record each result on its ticket and on RUY-390:
   - RUY-530 thaw numbers and RUY-531 fio (scheduler mq-deadline on the 860 EVO);
   - RUY-737 `udisksctl` names, the 860 EVO temperature and "Good";
   - RUY-738 overlay lows over SuperTuxKart;
   - RUY-730 the bell counts a controller connection and survives a reboot.

   The owner does the hands-on ones: RUY-766 (their stick FEDORA-S-DV with 4 root pictures), RUY-736 (Force quit on SeriousSamClassic), RUY-743 (two pads). Ask how they went.
2. **RUY-765 (high):** the reviewer's `revert-check.ps1` resolves a relative path against the main checkout. It wrote an empty `shell/qml/PadNumbering.qml` there and turned RUY-736's gate red. Fix it before the next review round.
3. **Lanes** (budget permitting):
   - RUY-770 and RUY-771 (small);
   - game page parts 2-4: RUY-532, 533, 534 (all in GameSection/GamePage; run them one after another or split the files);
   - RUY-744 app permissions;
   - RUY-528/526 compositor and EPP on the Dell.
4. **RUY-761** design work (above), then RUY-17.
5. **First architect audit (5b)**, still not run: focus on mock-only drift and on the check scripts' fixtures (two VM checks today had wrong signatures or names that their fakes accepted).
6. **Still waiting from lead-25:**
   - RUY-476/689 duplicate and RUY-634 re-scope;
   - triage inbox RUY-720..728;
   - order Ready (`sort_order`);
   - canvases for RUY-739 and RUY-749;
   - spikes RUY-731 and RUY-747.

## Concerns (ranked)
1. **VM fakes too lenient:** RUY-730's check called Post with the wrong arity and the host fixture accepted it. The service was only proven on the second VM run. Fixtures should check signatures against `api/dbus` (architect topic).
2. **Load flakes:** tst_profile_admin failed three times under load (fixed in a36bdb8a); tst_controllers once (RUY-683). Parallel lanes plus gates still stress the host.
3. **Lost builder handbacks:** three times a HANDOFF was refused as a repeat. The lead verified each round from the worktree's last commit and `output/last-green-test.txt`, and told the reviewer to "verify yourself". This works, but the harness gap is not fixed.
4. **Still open from lead-25:** wake on hardware (RUY-707), co-op on hardware (RUY-681), stuck `python3 -` processes (RUY-727).
5. **Weekly budget:** 69 % used at last check. Expect one lane until the week resets.

## Process changes in lead-26
- When a builder's handback is lost, verify the round from the worktree's last commit and the green marker, then send the reviewer to verify independently.
- Shared pad identity across Devices1/Input1/UPower is filed as RUY-764 (from RUY-743).
- 04 §5 has an empty-state pattern (from RUY-766's design review).

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-15 (lead-24) | f5e0726..0874b65 | 5 merged, 10 filed | rounds 2 for 2; 1 spec gap closed; 9 filed | 1977 QML + 166 skips | 0.0.87 queue 28/28; Dell on 0.0.87 |
| 2026-11-16 (lead-25) | 0874b65..8864330 | 0 merged (owner held dispatch); 22 tickets written from owner requests | 1 owner-found gap (RUY-730); 2 board problems found; 2 PP issues filed | docs only (`dev.ps1 docs` green) | none |
| 2026-11-16 (lead-26) | 8864330..HEAD | 11 merged; 5 filed (764, 765, 766, 770, 771) | second rounds on 743 (3 rounds) and 524; 2 spec gaps closed; 2 VM-check bugs fixed | 2051 passed, 0 failed (RUY-524 gate) | 0.0.88 queue: all but RUY-770 and sample; Dell on 0.0.88 |
