# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**Budgets: stop at 75 % context**). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## State at the end of the 2026-11-06/07 session (written at ~40 % context; update if more happens)

- `main` is pushed up to `e7f7aff` (test ALL GREEN: 544 QML + 50 skips, Rust green). Image `0.0.49` and its ISO are **built and verified** (`vm-iso-check.ps1`: install 228 s, `RUYA_BOOT_OK 0.0.49`, `/var` 126 GiB, greenboot success); the ISO is `F:\RuyaOS\ruyaos-0.0.49-install.iso` (the owner reinstalls the Dell from it). It lacks T-205 (merged afterwards).
- **In flight (builders, worktrees under `D:\dev\RuyaOS-worktrees\`):** T-223 (battery chips, branch `t/T-223-batteries`), T-190 (Settings focus follow-ups, `t/T-190-focus`). Dispatched at `e7f7aff`, round 1. Next: `ruya-reviewer` each, merge, `dev.ps1 test` on main.
- **Merged this session** (all through `ruya-reviewer`): T-200 thermal (two lead fixes: VM parser, spec), T-214 developer guide (+ five wording fixes), T-206 gear (re-cut icon font), T-204 Dreamglass v2 (round 2: black frame in the pulse), T-209 colour themes (round 2: tests wrote to the real registry), T-208 wallpapers (round 2: contrast model, focus ring, Daylight), T-205 gliding highlight and liquid pill (round 2: CI package, idle clock). VM queue of `0.0.48-lead` all passed (devices 76, store 71, library 35, storage 87, sample 26; the three FAILs were script bugs, fixed).
- **Written for the backlog (owner requests):** T-226 system information, T-227 UI sounds and ambient themes, T-245 notification centre, T-246 achievements, T-247 play statistics (the one usage ledger; T-211 reads it), the first-party apps epic T-248 (HIG T-249, platform spike/ADR-015 T-250, RuyaKit T-251, template T-252, apps T-253..T-259). The `.play` epic T-228..T-244 was written by the other lead session. The board is split: front in `STATUS.md`, the rest in `STATUS-backlog.md` (`lint-board.ps1` reads both).

## First, in this order
1. Check `git worktree list` and the two builders' state (the notes above), review and merge them. T-205 is `done` but its image proof is pending: the **next image `0.0.50`** must boot (`qt6-qtshadertools-devel`, the `.qsb`, `GlassPill.liquid` true under a GPU session) and re-run the three fixed VM scripts plus `vm-audio-check.sh` (T-197 close-out). Build it when the builders' lanes are quiet; `free-space.ps1` after.
2. **T-164** (per-profile Wayland sockets, lead, NEXT, critical path; needs a whole session plus the Dell as the GL test: no `EGL_WL_bind_wayland_display` on KMS, pick a dmabuf integration). Then T-165/T-147 (Play does nothing until then).
3. Next builder tasks (two lanes): T-194, T-199, T-202, T-203 (image risk: one image lane, `VM (this task)`), T-213, T-226, T-227, then the lead tasks on the backlog file. Visual polish came first by the owner's order and is done except the Dell measurements.
4. The Dell: the owner reinstalls from the 0.0.49 ISO and reports (gear, Dreamglass v2 and frame times, themes, wallpapers incl. a real USB stick, thermal rows). The T-205 frame-time check and the liquid-pill default follow after 0.0.50.

## Concerns (ranked)
1. **STATUS.md is ~16 KB** (budget ~10): the board is split but the Open owner decisions and the session log are long; prune at the next session. 
2. **Owner decisions waiting** (STATUS "Open owner decisions"): telemetry consent/backend, Dolby/DTS names, update size vs the unshrunk image, controller brand art, HDR/VRR, Flatpak runtime in the image, **ADR-015 app platform and ADR-016 browser (Proposed, T-250/T-258)**, which first-party apps first.
3. Design decisions parked in the Inbox: `glassTint` gives text only 2.5:1 over white art, dark themes over bright art, avatar palette vs themes, the liquid pill's default and brightness.
4. Image lane and memory: one image build at a time, nothing heavy beside `make-disk.sh` (drop WSL caches first); `make-disk.sh`'s exit code lies, read the log. Unchanged: compositor performance (B-003), suspend (T-166), Turkish review.
5. Flaky: `Themes::test_switch_cross_fades_over_tintMs` was racy (fixed with `tryVerify`); "TEST WINDOW LOST ACTIVATION" appears sometimes in `shots` while passing.

## Host facts learned
- A `systemd-run`/`systemctl --machine=<user>@.host` call hands its stderr to PID 1: SELinux accepts a pipe of an unconfined shell but not a service's pipe or a file in `/root` (`image/CLAUDE.md`).
- Fast service loop without an image build: build in WSL (`CARGO_TARGET_DIR=/root/ruya-target`), `bootc usroverlay` on the target, `scp`, `restorecon`, restart.
- bootc-image-builder: a custom kickstart replaces its default and cannot be combined with `[[customizations.user]]`.
- `busctl --json=short` prints doubles as `4.0e+01`; SSH host keys change at every VM boot (use a scratch known_hosts); a leftover `rofiles-fuse` mount from a flatpak-builder run in WSL (`/root/hello-game*`) keeps a worktree under `/mnt/d` busy: `pkill -9 -f rofiles-fuse.*hello-game` then `fusermount -uz`.
- QSettings(org, app) always uses the native store (the registry on Windows): tests must use `DeviceSettings(iniPath)`.
- Heredocs with long markdown through the Bash tool can fail to parse: write task files with the Write tool.
- `git worktree remove` needs the Bash tool (Git for Windows), not PowerShell.

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-06 (build loop) | handoff..653c8ed | T-189, T-192, T-193, T-191, T-196, T-195 merged | 3 CHANGES_REQUESTED | 403 QML + 33 skips | image `0.0.47-combined` |
| 2026-11-06/07 (build loop) | e73e081..e7f7aff | T-200, T-214, T-206, T-204, T-209, T-208, T-205 merged | 6 of 7 needed a round 2 (2 real defects: pulse black frame, registry pollution; 1 CI break prevented; theme/wallpaper contrast model) | 544 QML + 50 skips | `0.0.48-lead`: queue all PASS; `0.0.49` ISO verified |

Older rows: git history of this file.
