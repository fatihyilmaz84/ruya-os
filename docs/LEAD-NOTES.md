# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns; autonomous after an hour without the owner (`scripts\lead-clock.ps1`); builders run nothing in WSL**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. Paper Plane is the source of truth (http://192.168.178.164:8687, project `RUY`). **Goals are formations** (`formation` lists them). This file is the lead's session record.

## State after lead-33 (Opus, 2026-11-18)

- **Review range:** acb7d04c..HEAD. **Paper Plane `changes` cursor:** 4921.
- **Merged (6 tickets + 1 lead commit), every merge gate green:**
  - RUY-826: a bare Wii Remote held sideways maps in inputd (`pad::model_keys`).
  - RUY-832: on a stickless pad the D-pad also moves the virtual left stick. The owner checked both on the Dell (menus, SuperTuxKart).
  - RUY-828: `.play` package reading runs in an unprivileged `systemd-run` helper.
  - RUY-829: `ruya-play` is a service: Play1 on the bus, Flatpak commit, image files, `vm-play-check.sh`. Verify was split out as RUY-834.
  - RUY-839: the helper starts without `--pipe` (see the VM finding below).
  - RUY-837: every app gets `--device=input`. New `Input1.PreparePads`: the profile's pads exist before the game starts. Neverball and Project Starfighter open their pad only at start.
  - f33f8a75: test runs mute the UI cues and trailer audio (owner request).
- **Image 0.0.91** (built at 89a2bdf5) is on the Dell and booted in the VM (`RUYA_BOOT_OK`). It holds 826, 828, 829 and 832, but **not 837 or 839**. The owner said to skip the next image for now.
- **VM finding (RUY-100):** under SELinux, PID 1 refuses pipe or file descriptors passed by a service through `systemd-run --pipe` (dontaudit, no AVC; permissive works). That broke every install. RUY-839 is the fix, still unverified in the VM. Scores: ruya-play 2.9, helper 0.9.
- **Dell:** test overrides `devices=input` remain for `org.neverball.Neverball` and `io.github.pr_starfighter.starfighter`; remove them once 837 is checked there. `bootloader-update.service` fails at boot (RUY-24). The shell measured 21 % GPU in 10 s: unknown whether the owner was using it.
- **No lanes or worktrees open**, apart from the kept `.claude/worktrees/design-pad-silhouettes-559410` (see lead-32). Its `settings.local.json` still has the old Paper Plane usage hooks, which is why `summary` warns about double usage events. Removing the hooks was refused by the permission check: ask the owner.

## Owner direction (in force, new this session)
- **RUY-838, game options:** a gear beside Play opens one options screen per Library item, for every source (Flatpak, `.play`, Steam).
  - Settings are per profile, with a "Use for all profiles" checkmark.
  - All profiles may change them; parental controls can restrict that later.
  - Narrowing permissions is always allowed. Widening is allowed only in developer mode with an admin PIN (lead's proposal; the owner has not objected).
  - Steam's own settings stay in Steam (no editing its files).
  - Design first, after the weekly reset.
- **Code Mode:** try it in one terminal lead session after the reset and compare tokens per ticket. The owner has to set the environment variable himself.
- Still in force: Steam is first-class, no hacks (RUY-815); `.play` foundations first (RUY-780).

## First thing next session
1. **The next image** (when the owner allows), then:
   - RUY-100's re-run: `vm-play-check.sh check <zip> <ruya-pack>` and `helper`. Check that PID 1 opens the file stdio under `DynamicUser` and `ProtectSystem=strict`.
   - `vm-input-check.sh startpad`.
   - On the Dell: Neverball and Starfighter get the pad from the start. Then remove the overrides.
   - All of these are queued on RUY-390.
2. **RUY-494 (high, the owner asked):** every Godot 3.6 X11 game dies at start. xwayland-satellite panics on `wl_shm_pool` "invalid width, height or stride (Nx25)". ROTA (`net.hhoney.rota`) is a free reproducer. A `WAYLAND_DEBUG` trace in the VM is the lead's job.
3. **RUY-825:** re-check Steam's controller config after a screen-saver wake on 0.0.91 (it has RUY-814).
4. **After the weekly reset (2026-11-20 18:00):** the architect audit (focus questions in lead-32: RUY-825/812, 817, 820, 815) and RUY-838's canvas.
5. **Ready, in order:** RUY-834 (Verify), RUY-840 (a failed launch drops the held game's pads), RUY-102 and RUY-104 (unblocked once RUY-100 passes in the VM).

## Concerns (ranked)
1. **`.play` installs are not proven on Linux** until RUY-100's re-run passes.
2. **Godot 3 X11 games don't start** (RUY-494).
3. **Steam focus** (RUY-825, RUY-812).
4. **Weekly plan at 91 %:** cheap work only until the reset.
5. `shell/CLAUDE.md` is 7.7 KB against a budget of about 7 KB: prune it at the next lead session.

## Process changes in lead-33
- **Lead:** I cut `merge-gate.ps1`'s output with `Select-Object -Last 8` and lost the name of a failing test (RUY-828's first gate; the re-run was green). **Read the gate's whole summary.** It already prints the FAIL lines.
- **Builders:** none. RUY-829 came back `partial` with a coherent split (Verify), as briefed.
- **Tests:** test runs no longer play sounds.
- **Paper Plane:** `create` refused a description with `## Acceptance` instead of `## Acceptance criteria` and created nothing. That is fine, but the error message doesn't say the ticket was not created.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-17 (lead-31) | 09defa5..11ae518 | 6 merged (814, 105, 818, 819, 823, 821); 9 filed | 105: one round 2; 1 lead review fix | 2207 passed, 0 failed; GitHub CI green | none |
| 2026-11-18 (lead-32) | 11ae518..acb7d04 | 2 merged (822, 504); 1 filed (825) | 822: 1 lead fix; 504: round 2 for missing shots | 2207 passed, 0 failed | Dell: RUY-825 diagnosis (hw) |
| 2026-11-18 (lead-33) | acb7d04..HEAD | 6 merged (826, 832, 828, 829, 837, 839) + 1 lead commit; 13 filed (827, 830, 831, 833-835, 838-841 and 829's split 834); 13 and 836 cancelled | 829: round 2 (fail-closed reconcile, dev docs); 837: API review clean; 1 gate flake | 2216 passed, 0 failed (RUY-837 gate) | 0.0.91: VM boot OK; vm-play-check 12/25 (SELinux, fixed by 839, unverified); Dell 0.0.91 (hw: Wii Remote) |
