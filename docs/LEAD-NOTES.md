# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL; check D: before dispatching (4b.2); clean up every merged worktree with `scripts\worktree-done.ps1`**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-44 (Opus, 2026-11-23; the owner was present all session)

- **Review range:** e6c8d606..HEAD (every builder branch had a review; RUY-1099 round 3 was checked by the lead after its reviewer stalled). **Paper Plane `changes` cursor:** 8266.
- **Merged and Done:** RUY-1063 (B9a uinput for the signed-in profile; round 2 freezes a leaving profile's Steam), 1100 (GE-Proton11-13), 1098 (ruya-platform crate, Platform1.xml with Lifecycle and Manage, shared crates ruya-users and ruya-profiles-client), 1102 (the Steam reader's transient-unit sandbox: ProtectHome=read-only + SystemCallFilter=~@network-io, measured on the Dell), 1099 (ruya-session drives Lifecycle; at power off the 5 s save window is part of the 30 s grace, lead decision C), and the design session's 04 §5.5 (Downloads page and flat tray, owner OK). Lead: CLAUDE.md pruned to 10.7 KB; ADR-022 "Build decisions" (root-owned per-profile permission store, unicast Lifecycle, no pre-freeze notice) and ADR-046 pt 4; RUY-957 chain disk guard (In Review, unverified). Last gate on main: 2384 QML passed, 0 failed (Rust about 2690).
- **Owner today:** B9b (RUY-1090) stays paused with the Steam goal; Platform1 keeps priority. Monster Boy on the Dell: the controller works and the install screen shows the art (RUY-1039 and 1038 on hw); asked: does a save survive a relaunch (RUY-1007 closes on that).

## Do first
1. **WSL disk.** 0.0.106 never built: F: filled up mid-build, ext4 went read-only and the distribution would not start (recovered: old .oci removed, `wsl --shutdown`, journal replay). `free-space.ps1` was compacting when lead-44 ended (`output\free-space-lead44.txt`). After the prune **WSL still reports 105 GB in use** (podman images were 57.6 GB): find what holds the rest before building (RUY-957 comment). Then `image-chain.sh 0.0.106 oci`; the new guard refuses below 30 GiB on F: or C:.
2. **VM queue on 0.0.106** (RUY-390 comments): default list (now with `vm-library-check.sh steam`), `vm-input-check.sh uinput` (RUY-1063), `vm-runner-check.sh check` and `vm-play-check.sh launch-windows` (11-13). Then `dell-update.sh 0.0.106` and the Dell list: RUY-1063 criteria 9-10 (a p1 uinput keyboard reaches no PIN pad; the Half-Life stick through Steam's virtual pad), RUY-1097 (a frozen Steam client thaws and works), Steam games in p1's Library (RUY-1102), UT/Monster Boy on 11-13 and a Bluetooth DualSense under Proton. Dell SSH: `-i ~/.ssh/ruyaos_dev`; /root has the pre-1063 `vm-inject-key.py` (replace it with main's once 0.0.106 is on).
3. **Platform1 (formation RUY-1095):** RUY-157's image part is the lead's (unit, bus policy with the lint exceptions, `vm-platform-check.sh`; its comments list what to cover, including CAP_SYS_PTRACE/SELinux for the /proc reads and unicast through xdg-dbus-proxy), then RUY-158 (harness; its comment lists the sample and conformance cases), then 452/454. RUY-456 (secret-store spike) can run beside it.
4. Design-ready builder work: RUY-1109 (flat tray), RUY-30 (Downloads page; waits on RUY-28/29).

## Concerns (ranked)
1. The build host's disk (above): two F: overflows; the 105 GB inside is unexplained.
2. Steam Input under the satellite is still unproven even with B9a; keyboard/mouse templates need B9b (paused).
3. Platform1's identity has only been proved in a spike; the image part (caps, SELinux, proxy) is where it can still break.

## Process changes in lead-44
- **System:** the F: overflow repeated (RUY-957 filed in lead-38, never built): the chain now cleans up and guards the host drives (a check, not a rule). A builder's hardware assumption (RUY-1083: does systemd-run expand %h?) was left as an inbox line and cost a Dell regression: `vm-library-check.sh steam` is now in the VM queue, so the next one is caught in the VM.
- **Lead:** design calls written into ADR-022 before dispatch saved rounds (1098's only blocker was the lead's own change). Two builder handbacks were refused as a second report; the ticket's handover and Outcome had everything, so read the ticket first. **Paper Plane:** issue EnigmaNL/PaperPlane#18 (a refused create names a ticket id that does not exist). **Tests:** none changed.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-22 (lead-42) | 52e8407..74952c9 | 11 merged, 3 closed, architect audit (ADR-041..045), 4 Dell diagnoses; filed 1040-1069 | round 2+ on 1038 (x2), 1039, 1050, 960, 1051, 1052, 52: all real | 2371 QML + 2540 Rust, 0 failed | 0.0.103 built, skipped; 0.0.104 building |
| 2026-11-22 (lead-43) | 74952c9..e6c8d60 | 5 merged + 1 lead fix, 2 spikes + 1 study, ADR-046, 2 owner decisions, Steam paused; filed 1070-1095 | round 2+ on 1056, 1054 (x2), 1067, 1063: all real | 2381 QML + 2572 Rust, 0 failed | 0.0.104 17/17 + 11/12; Dell 4/4; 0.0.105 built |
| 2026-11-23 (lead-44) | e6c8d60..HEAD | 5 merged + design merge, RUY-157 split (1098/1099), 1 lead fix (957), 1 design canvas; filed 1097-1111 | round 2+ on 1063, 1098, 1099 (x2): all real; Dell found the RUY-1056 reader regression (1102) | 2384 QML + ~2690 Rust, 0 failed | 0.0.105 VM 17/17 + a/b; Dell 3/4 (reader FAIL, fixed); 0.0.106 failed (F: full) |
