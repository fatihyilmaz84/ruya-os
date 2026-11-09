# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets and "Lead efficiency": hand off at 50-60 % context; no no-op turns**). **Rewrite this file at the end of every lead session**; keep it under about 6 KB. History lives in the STATUS session log and git.

## State at the end of the 2026-11-09 session (lead-7, Opus, handoff at about 50 % context)

- **Merged and reviewed:** T-340 (ruya-session follows adopted apps over one `systemd-stdio-bridge` per profile manager), T-348 (Settings > Audio > Output list, test sound), T-365 (lead: a pulse server per profile, `ruya-pulse@ruya-<id>`, apps get `PULSE_SERVER`), T-375 (lead: BlueZ `UserspaceHID=false`), T-376 (shell hides L0 and stops the ambient bed behind an app), T-361 (deterministic focus/layout tests), T-360 (see the last commit: merged or still in flight). `main` pushed at `a19ed7b` mid-session; push again at the end.
- **Images:** 0.0.59 built from the T-365 branch, VM: boot OK, `vm-session-check.sh check` 37 PASS, `display` 37 PASS (profile sound socket), `restart` 1 FAIL on the image's binary = the zbus `unixexec` escaping bug (fixed in `4a51783`, passed with the fixed binary bind-mounted). **The Dell runs 0.0.59** (rollback 0.0.58): STK through the shell has a running output stream of `ruya-p1`; bluetoothd 0 % with the DualSense (was 10-12 %).
- **No builder in flight** unless T-360 is still open (worktree `D:\dev\RuyaOS-worktrees\T-360`, branch `t/T-360-audio-service-follow-ups`; round 2 = new outputs of headphone kinds start at 40 %, line-level at 100 %: lead decision for hearing safety; then `ruya-reviewer`).

## Next, in this order
1. **Image 0.0.60 from `main`** (`scripts/image-chain.sh 0.0.60 oci`; it now copies `config.toml` in worktrees) and the VM queue in STATUS (T-340 restart with the fix, T-365 start bound, T-375 `vm-devices-check.sh bluetooth`, T-376 no `ruya-shell` stream behind an app, T-360 `vm-reboot-check.ps1 -SavedOutput`). Then the Dell (oci route) and the T-376 hw list in the Inbox (GPU share, `Texture t7` line, dark frame, bed pop).
2. **Ruya Hub planning** (owner request): requirements in `docs/specs/07-hub-requirements.md`. Gap analysis (lead-7): the overlay is the Guide overlay / T-147 quick menu (ready, deps done) = "Hub v1"; gaps: quick-settings rows over existing Devices1, microphone in `Devices1.Audio`, brightness (DDC/CI, honest "unsupported"), performance panel (CPU/RAM/temps now; GPU/VRAM/FPS need a spike: the compositor can count surface commits), configurable shortcuts, overlay latency budget. The document assumes gamescope and a separate Hub service (wrong: the shell is the compositor; no new service). **Owner questions asked, answers pending:** the name clash with ADR-020's `ruya-hub`/`Hub1` (recommended: overlay keeps "Ruya Hub", rename the unbuilt service to `ruya-gamedata`/`GameData1`); V1 exclusions mean "not in the overlay"; a game surviving a shell crash (recommended: not now, it reopens ADR-002); Quick Resume across reboots (later, research); test hardware (spending). Write the ADR and 6-8 tasks once answered.
3. **Ruya Input:** T-366 (lead spike: InputPlumber is not in Fedora 44; decide inside ADR-003; write `06-input.md`), then T-367 a game sees the pad. Owner's requirements: `docs/specs/06-input-requirements.md`, ADR-024.
4. Builder lanes: T-363 (Flatpak scope accounting), T-362 (xdg-output: STK's low resolution), T-359, T-364.

## Dell (192.168.178.109, root with `~/.ssh/ruyaos_dev`; standing permission, owner 2026-11-09 again: "full control")
0.0.59 (rollback 0.0.58). **No HDMI port: TV and sound are on DisplayPort** (PipeWire still names the profile "HDMI"). Profile p1 "Fatih" (admin, has a PIN: the owner gave it for checks; it is in Claude's local memory, never in the repo). STK in the system Flatpak installation; one DualSense bonded and connected. **Lesson:** a game started by hand (`systemd-run -M ruya-p1@`) must be stopped by its `app-flatpak-*.scope`, not its unit: two leftover copies dropped the owner's STK from 40 to 15 FPS.

## Concerns (ranked)
1. Profiles are full-rights clients of the shell's PipeWire (can list, mute, move each other's streams, record monitors): decide the isolation (T-365 review, B-007, T-220). 2. Hidden L0 still sampled during the pills' fade-out (the `Texture t7` warning candidate). 3. The dmabuf plugin uses private Qt API (every Fedora Qt update needs a rebuild). 4. `shots` reds on main at tst_store_ui:81, tst_system_info:502, tst_wallpaper:898 seen by two reviewers, green for a builder: same plain-read-after-change class (PATTERNS.md section). 5. CI unverified.

## Host facts learned
- zbus 5.19 does not percent-decode `unixexec` arguments (busctl does): build `Transport::Unixexec` typed.
- Sandboxed user units imply `PrivateUsers`: `setfacl` for another uid needs the `+` prefix.
- `/var/tmp` in the image is noexec: bind-mount test binaries from `/etc`.
- Git Bash rewrites `/mnt/c/...` for `wsl.exe`: `MSYS_NO_PATHCONV=1`. Image timings: build 27 min, qcow2 17 min, oci 7 min, Dell copy + switch + reboot about 8 min.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-08 (lead-4) | d09da99..01f31ca | T-290..T-324 (13) | 8 of 13 round 2; FLAC sample-rate-0 bed bug found | 931 QML | `0.0.54` PASS |
| 2026-11-08/09 (lead-5) | 01f31ca..dae44c0 | T-330, T-336, T-335, T-337, T-334, T-356, T-349, T-331 | most needed rounds; the dead-end focus bug found with the owner | 987 QML + 77 skips | `0.0.55`, `0.0.56` PASS |
| 2026-11-09 (lead-6) | c5e2d67..d4157dd | T-164, T-322, T-347, T-285, T-358 (lead) | T-164 hidden app vs updates; T-322 silent-pass VM check; T-347 executor blocking; T-285 untested hint | 1001 QML + 77 skips | `0.0.57`, `0.0.58` PASS; Dell STK on GPU |
| 2026-11-09 (lead-7) | d4157dd..main | T-340, T-348, T-365 (lead), T-375 (lead), T-376, T-361, T-360? | 5 of 6 needed a round 2: T-348 greyed other-profile outputs (undid T-347), T-376 silent-pass VM step (no jq), T-361 a retry that weakened a focus check, T-360 100 % on new headphones (lead's task text), T-340 escaping bug found in the VM; T-365 `:` env bug found by its own test | 1012 QML + 79 skips | `0.0.59`: check/display PASS, restart FAIL (fixed); Dell 0.0.59 |
