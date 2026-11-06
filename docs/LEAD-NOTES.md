# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Lanes at handoff (2026-11-06)

None running; `git worktree list` shows only the main checkout. **Owner, 2026-11-06: no new tasks are created or dispatched until the owner says so.** T-189..T-194 exist as `todo` (planned before that instruction) and must not be dispatched without the owner's word. T-162 was done by the lead this session (it is `[lead]` work).

## Review range

- **Last reviewed commit: the handoff commit of this session.** The range since `372fa87` held only docs commits plus T-162, which the lead wrote itself (no reviewer; the VM check is its test).
- **Last VM verification: image `0.0.44-t162` of the working tree at the T-162 commit** (smoke `RUYA_BOOT_OK`, `vm-session-check.sh` 45 PASS, `vm-devices-check.sh` 57 PASS with `-Audio`). Store, library, storage and update checks were not rerun (nothing they test changed; the new PipeWire drop-ins only touch `ruya-shell`'s audio, which the devices check covers).

## Concerns (ranked)

1. **Critical path: T-164 -> T-165/T-147** (`[lead]`). T-162 is done: `Session1.Launch` starts a real Flatpak as the profile user. T-164 gives that app a Wayland socket and shows its window in the shell. Read T-162's Outcome first: the app lives in `app-flatpak-*.scope` (not in our unit), the spawner's stderr is a file (SELinux), and `WAYLAND_DISPLAY` is not passed yet (`main.rs` passes an empty env: T-164 sets it per profile, through `Session::new`'s `env`, which is a fixed list today, so it needs a per-launch hook).
2. **The Dell (B-002).** The owner installed the 4 Nov ISO (0.0.40) and got a text login (the T-178 bug). A fresh ISO of `0.0.44-t162` is on `F:\RuyaOS\` (built from `localhost/ruyaos:dev`; `vm-iso-check.ps1` passed on it: installs in QEMU, boots to the shell, greenboot success). Wait for the owner's report from real hardware (first KPIs, GPU, controllers, Wi-Fi under the NetworkManager deny rule).
3. **Tests that cannot fail** (T-189 planned, undispatched; PLANNING.md Lessons has the rule). This session's lesson: a check that "passed" `Stop` while the app still ran, because it looked at the unit and not the process. Assert the thing, not its proxy.
4. **Owner scope decisions** (recorded): media/streaming apps, Steam (Proton) and RetroArch are separate Store apps, out of the first MVP; blur and shadows stay the default look; design pass wanted but no tasks written.
5. **F: drive** (owner, 2026-11-06, NTFS, 119 GiB, USB, full control granted; memory `f-drive-for-images`): only the ISO is on it. Moving `output/` there is an Inbox line; do it with a junction when no VM or build runs.
6. **STATUS is ~14 KB** (budget ~10 KB): prune the Open owner decisions and the "Decided" paragraph when planning resumes.
7. Older: compositor gaps (B-003, suspend T-166), `caller_is_admin` copied in two services, stale canvas boards, Turkish wording review, the registry of `ruya-session` is lost on a restart (Inbox).

## Host facts learned

- `systemd-run`/`systemctl --machine=<user>@.host` hands its stderr to PID 1; SELinux lets PID 1 write a pipe of an unconfined shell but not a service's pipe or a file in `/root` (call hangs or "Connection reset by peer"). In scripts: `2>&1 | cat`; in a service: a file in its `RuntimeDirectory`. Recorded in `image/CLAUDE.md`.
- Fast loop for a service change without a 30-minute image build: build in WSL (`CARGO_TARGET_DIR=/root/ruya-target cargo build --release --locked -p <crate>`), `bootc usroverlay` in the VM, `scp` the binary, unit and policy, `restorecon`, restart. Discarded on reboot. Always finish with a real image build (a missing `install` line in the Containerfile only showed there).
- `vm-devices-check.sh` needs `smoke-test.ps1 -Audio`; an `ssh ... bash script` may not return if the script leaves background jobs (read the log from a second ssh).
- `git worktree remove` can fail "Directory not empty": `rm -rf` from Git Bash, then `git worktree prune`. Never overlap an image build with `dev.ps1 test` or `vm-iso-check.ps1`.
- `diskpart /s` formats a USB drive even when its output is empty (PowerShell `Format-Volume` said "Invalid Parameter").

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-04 | 9b77857..b4733f4 | T-155, T-157, T-159 (+ T-130 fresh read) | 0 / 7 tasks planned (T-162..T-168). Process: builder/reviewer agents, worktree lanes, lead-only STATUS, VM queue, `free-space.ps1`, shots lock (owner) | 271 + 22 skipped QML, 242 Rust | not run |
| 2026-11-04 | 2c134ce..handoff | 12 merged: T-167, T-168, T-136, T-158, T-137, T-169, T-163, T-160, T-171, T-172, T-170, T-144 | 6 CHANGES_REQUESTED, 3 lead fixes | 327 + 28 skipped QML | `0.0.32`/`0.0.33` ok |
| 2026-11-04 (late) | handoff..223d7ed | +7: T-175, T-176, T-161, T-173, T-145, T-177, T-174 (19 in the session) | 10 CHANGES_REQUESTED in the session; lead fixes: T-173 stop_scan, T-176 shots log, scratch known_hosts | 346 + 28 skipped QML | lead `0.0.37` ok |
| 2026-11-05 | 4c0e713..handoff | 11 merged: T-178..T-188 | 6 CHANGES_REQUESTED (a real regression in T-182, a vacuous test in T-184, VM checks that could not pass in T-183 and T-188, a design miss in T-185); 6 tasks planned (T-189..T-194), not dispatched | 381 + 30 skipped QML | lead `0.0.42` ok: smoke, devices 57, store 67, library, storage 98 |
| 2026-11-06 | 372fa87..handoff | T-162 (lead-written) | 0 reviews (no builder); 5 defects found by the VM check in my own work (stderr pipe, scope, linger race, Containerfile install line, check script stderr) | 381 + 30 skipped QML, Rust green | `0.0.44-t162`: smoke, session 45, devices 57 |

Older rows: git history of this file.
