# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`; a Sonnet lead escalates hard-to-undo decisions to an Opus agent ("Model tiers")**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-53 (Sonnet, 2026-11-26; the owner was present: "two lanes", "medium is fine", "dont stop dispatching", "keep going until your budget is filled, then hand off")

- **Owner rules (memory `quick-wins-until-reset`):** until the weekly reset **2026-11-27 18:00 UTC** simple quick wins and, now allowed, medium tickets, Sonnet (Opus for complex), two lanes (lead-53 ran three at the end). Weekly plan was 87 % at the last check. **First ticket after the reset: RUY-1190** (slow app-permissions page). Then RUY-1191, 1192, the RUY-1183 players' Hub review, RUY-28 round 2 (worktree `RUY-28` stays), ROM chain from RUY-1152, Platform1 1130/1131/1137, RUY-781, RUY-1186.
- **Review range:** 8bd6cae8..HEAD (this handoff commit). **Paper Plane `changes`:** not read; lead-53's tickets are RUY-1163..1243, read `list` by number from RUY-1216.
- **Merged (21; every merge gate green, last full run 2545 QML, 0 failed):** 1176/1177/1178 (Options menu on Settings rows: `Page.surfaceOptions`; Bluetooth, Network, Storage; icon font re-cut in WSL; the Hold ring fades a row's value, 04 §5), 1222/1230/1240 (one `SettingsPane` row list and refocus rule; Storage `rowMode`), 1225/1227/1233/1234 (Storage hints, retranslation), scripts: 1163, 1216, 1217 (`lint-vm-checks.ps1 -Quick`; the gate asserts a complete lint run), 1221, 1223, 1231/1232 (`scripts/lib-bash.ps1`), plus 1215, 1220, **1235 + 1238 (the LibreQuake fix, below)**. Cancelled with a comment: 1212, 1200.
- **LibreQuake on the Dell (owner report "cannot control it, worked before"):** not a 0.0.109 regression. Ironwail saved `joy_device "-1"` at the update reboot: the game was frozen behind Home, `StopAll` thaws first, `FrozenChanged(false)` released the shell's pad hold, route `shell` destroyed the pad 0.9 s before the game exited. Fixed in two tickets (shape decided with an Opus review, checked in the code): **RUY-1235** Session1 `AppStopping` signal before the thaw; **RUY-1238** the shell's one stop hold (`stopPadHold`, `InputRoute.heldInFront`) for Close, Force quit and shutdown; 06 §5.2, developer page (experimental). The Dell instance was healed by hand (`joy_device 0`). **Not yet verified on a machine: needs an image.**
- **VM queue on image 0.0.109 (from ae2f9c41): PASS 22 of 22** (recorded on RUY-390/1196); **Dell is on 0.0.109** (`bootloader-update` fails: Secure Boot, known). 0.0.109 carries nothing of lead-53, nor RUY-1197 and RUY-728.

## In flight at handoff
Nothing: no builder, no review, no VM, no WSL job. Leftover worktrees: `RUY-28`; `.claude/worktrees/design-*` (another session's, leave).

## Do first
1. **Build the next image** (`image-chain.sh`, about 3 h), then the VM queue (this session's list plus `vm-session-check.sh check` (bus order AppStopping, FrozenChanged, AppExited), `vm-profiles-check.sh create`, `vm-reboot-check.ps1 -PadShutdown` for RUY-1238), `dell-update.sh`, `free-space.ps1`. Then ask the owner to test LibreQuake after a reboot with the game frozen behind Home.
2. **Owner decisions waiting:** RUY-1239 (a game frozen behind a profile switch loses its pads; recommendation accept); RUY-1237 is approved ("Reset game data…" on the game page's Manage group; sets the whole data aside, saves included, because Ironwail keeps its cfg next to the saves; complex, contract first, read Library1 first); the owner may want a settings-only reset (needs the package to declare config files).
3. **Design tickets mine to decide:** RUY-1219 (Options sheet fill 90 %, anchor in the bottom fade), 1226 (a note changing the sheet height: keep the top), 1229 (two landing rules for a removed focused row: 04 T-356 vs 02 §1.7; `ControllersPane.refocusAfter` is the only override, its covered branch may be dead).
4. **Plan from the inbox:** RUY-1242 (Session.h mirrors every SessionBackend signal; RUY-1238's reorder hid it from the duplicate lint: do soon), 1243 (sign-out release of the stop hold has no test), 1224 (drive-menu glyphs: lead re-cuts the font), 1241 (CI gap of the quick-lint guard), 1213 (section 2 of the lint, `test-vm-checks.sh`, is 272 of 278 s), 1228, 1218, flaky tests under load (1046 `tst_wallpaper` seen twice, 1167, 1169).

## Concerns (ranked)
1. **Weekly plan about 87 %+; reset 2026-11-27 18:00 UTC.** Dispatch little before it.
2. The stop hold, the Session1 signal and the three docs clauses are host-verified only; the real behaviour is VM pending (see Do first 1).
3. RUY-1186 (a game frozen 71 min spun at 100 % after Resume), RUY-1184 (Steam Input double input): unverified.
4. Instruction budgets: root `CLAUDE.md` about 10.9 KB, shell/CLAUDE.md 7.6 KB: still over.
5. An architect audit is due (none recorded since lead-49's); RUY-1198 needs one.

## Process in lead-53
- **Worked:** read the code before writing a ticket (1212, 1200, 684, 1168 skipped with a comment, not wasted builders); a design reviewer's "one rule with numbers" (Hold ring fades the value); the same blocking findings to the SAME builder; an Opus advisor for the shutdown shape; the lead re-cutting the font on the branch before review; tiny or tests-only diffs reviewed by the lead without an agent; a diagnostic agent on the Dell found the LibreQuake cause in 17 minutes.
- **Mistakes:** (1) `update description=` REPLACES the description (RUY-1176's was overwritten, restored from my earlier read): send the full text or use `comment`. (2) A reviewer's hand mutation wrote into the MAIN checkout through a relative .NET path: builders and reviewers are now told to use ABSOLUTE paths inside their worktree. (3) Ticket glyph code points were wrong; never trust code points in a ticket. (4) `create` has no `blocks` (use `update blocks=[...]`).
- Process: none changed in files.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-25 (lead-52) | ae2f9c41..8bd6cae8 | 10 merged; filed 1208-1215 | round 2 on 1208 and 612: both real | 2498 QML, 0 failed | image 0.0.109 built (CHAIN OK); queue not run |
| 2026-11-26 (lead-53) | 8bd6cae8..HEAD | 21 merged, 2 cancelled; filed 1216-1243 | round 2 on 1163, 1177, 1178, 1230, 1217 (two real gate holes): all real; a stale 04 sentence and 2 wrong glyph code points fixed; 3 docs clauses from the API review | 2545 QML, 0 failed | 0.0.109 queue 22/22; Dell updated to 0.0.109 |
