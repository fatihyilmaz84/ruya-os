# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md) (**read its new "Budgets" section: stop at 75 % context**). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Handed off at 87 % context (2026-11-06). First, in this order

1. **The ISO for the Dell.** `localhost/ruyaos:dev` is `0.0.47-combined` (slim image + Bluetooth firmware + pairing fix + `QT_AUDIO_BACKEND=pulseaudio`). Building the installer ISO with the whole-disk kickstart (`image/bib/iso-kickstart.toml`, key injected by `scripts/bib-iso-config.py` because bib refuses generated users next to a custom kickstart) was being retried: `make-disk.sh anaconda-iso > output/iso-comb4.log` (a monitor was waiting for `DONE rc=`). Earlier attempts: kickstart/users error (fixed), then an osbuild failure at the squashfs stage with no message, and the qcow2 failed with `Cannot allocate memory` (a **partial `output/qcow2/disk.qcow2` must be rebuilt**). Suspect: memory contention with builders' `dev.ps1`/cargo and WSL page cache; run **nothing else heavy** while `make-disk.sh` runs (`echo 3 > /proc/sys/vm/drop_caches` in WSL first). When `output/bootiso/install.iso` exists: `scripts\vm-iso-check.ps1` (now uses a 128 GiB disk and **fails unless `/var` is at least 85 % of it**: this proves the whole-disk kickstart; if bib ignored it, the ISO check fails loudly). Then copy the ISO to `F:\RuyaOS\` and tell the owner. If the custom kickstart cannot work, fall back: drop it, keep the 70 GiB cap, and tell the owner the disk is grown by hand (`growpart /dev/sdaN`, `xfs_growfs /var`, done on the Dell already).
2. **Push.** 37 local commits are unpushed. `scripts\push-main.ps1` (runs `dev.ps1 test`: not during an image build).
3. **Review T-200** (thermal; branch `t/T-200-thermal` at `f863c1b`, worktree `D:\dev\RuyaOS-worktrees\T-200`; the builder's HANDOFF says done, 420 QML + 231 Rust, shots reviewed; open: VM check `vm-devices-check.sh thermal`/`thermal-fake`, the Dell). Dispatch `ruya-reviewer` when no image build runs.
4. **T-214** (developer guide, priority) builder is running in `D:\dev\RuyaOS-worktrees\T-214`; its HANDOFF comes by notification. It also writes `scripts/lint-dev-docs.ps1`; `vm-sample-check.sh` is a lead run.
5. **T-197** (shell crash on Bluetooth headset disconnect; lead): the fix is in the repo (`ruya-compositor@.service` has `QT_AUDIO_BACKEND=pulseaudio`) and on the Dell as an `/etc` drop-in; the owner says the crash is gone. Left: five connect/disconnect cycles counted, `vm-audio-check.sh` on the new image, the Outcome, set `done`.
6. **VM queue** (one image, then each check; `STATUS.md` lists it): T-191, T-192, T-193, T-196, T-200 checks plus T-195's items already done by its builder. Needs `-Audio` for devices. Free space after: `scripts\free-space.ps1`; WSL `.vhdx` is ~48 GB on C: (13 GB free): `wsl --manage FedoraLinux-44 --compact` between builds, never while a build runs. F: (NTFS 119 GiB, owner's) holds only the ISO so far.

## The Dell (owner's test machine, 192.168.178.109, root with the dev key; may be off)
Installed from the 0.0.44 ISO, runs that image plus **overlays that vanish on reboot**: Bluetooth firmware (`dnf install iwlbluetooth-firmware` in `bootc usroverlay`), the fixed `ruya-devices` binary (`output/ovl/ruya-devices`), and a real file `/etc/systemd/system/ruya-compositor@.service.d/10-audio-backend.conf`. `/var` grown by hand to 464 GB. Controller (DualSense, bonded) works; the WH-1000XM4 headset must be re-paired once with the fixed code (`Bonded: yes`). After the new ISO is installed, nothing needs overlays; the pad must be paired again (T-203 removes the need for a keyboard).

## Concerns (ranked)
1. **STATUS.md is 23 KB** (budget ~10 KB): prune the Inbox, Open owner decisions and the Decided paragraph first (move to the archive); the board itself has ~40 rows.
2. **Critical path T-164** (per-profile Wayland sockets; lead; T-162 is done and vm/hw-verified) -> T-165/T-147. Not started; needs a whole session and the image lane; the Dell is the GL test (no `EGL_WL_bind_wayland_display` on KMS: pick a dmabuf integration).
3. **Image lane and memory**: one image build at a time and nothing heavy beside `make-disk.sh` (this wasted ~1.5 h this session). Consider telling builders to avoid `dev.ps1 test` while the lead builds, or lowering parallel lanes to one during image work.
4. **Owner decisions waiting** (all in `STATUS.md`): telemetry consent/backend/retention/privacy notice (T-224/T-225), Dolby/DTS names (T-219), update size vs the unshrunk image (rechunk/flatten, from T-195), real brand art for controllers (T-199), HDR/VRR after the spikes.
5. Unchanged: compositor performance (B-003), suspend (T-166), Turkish review, `caller_is_admin` copied in two services.

## Board at handoff (todo, in the order added; builder unless marked)
T-190, T-194, T-164 [lead], T-165, T-147, T-166 [lead], **T-214 (priority, running)**, T-197 [lead, in progress], T-198 [lead] display resolution/DPI, T-199 device icons, T-201 [lead] stuck-process recovery, T-202 screen saver/power saving, T-203 pair a controller without a keyboard, T-204/T-205 Dreamglass v2 (205 lead), T-206 gear icon, T-207 [lead] faster BT reconnect, T-208 wallpapers, T-209 colour themes, T-210 profile customisation, T-211 [lead]/T-212 parental controls, T-213 time zone, T-215 [lead] saves backup, T-216 [lead] network options, T-217..T-219 [lead] input mapping / HDR spike / audio formats, T-220 privacy, T-221 app management, T-222 [lead] refresh-rate/VRR, T-223 status batteries, T-224/T-225 [lead] telemetry and crash reports. Suggested next dispatches (two lanes, no image build): T-206 (small) + T-223; then T-203 + T-213; keep the image lane for the lead (ISO, VM queue, then T-164).

## Merged this session (with `ruya-reviewer` unless noted)
T-189, T-192, T-193, T-191, T-196 (round 2), T-195 (+ my hardening commit); T-162 and the Bluetooth/audio/installer fixes by the lead; many task files written (T-197..T-225) from the owner's requests. Owner scope decisions: media apps separate; blur/shadows default; hold on new tasks lifted; F: drive for images; telemetry wanted with user control; developer docs a priority.

## Host facts learned
- A `systemd-run`/`systemctl --machine=<user>@.host` call hands its stderr to PID 1: SELinux accepts a pipe of an unconfined shell (`2>&1 | cat`) but not a service's pipe or a file in `/root` (`image/CLAUDE.md`). `ruya-session` uses a file in its `RuntimeDirectory`.
- Fast service loop without an image build: build in WSL (`CARGO_TARGET_DIR=/root/ruya-target`), `bootc usroverlay` on the target, `scp`, `restorecon`, restart. Discarded on reboot.
- `make-disk.sh` ignores osbuild failures in its exit code (the `DONE rc=0` line lies): read the log.
- bootc-image-builder: a custom kickstart replaces its default and cannot be combined with `[[customizations.user]]`.
- A fresh worktree rebuilds from scratch; `git worktree remove` may need `rm -rf` then `git worktree prune`.
- `diskpart /s` formats a USB drive when `Format-Volume` says "Invalid Parameter".

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-11-05 | 4c0e713..handoff | 11 merged: T-178..T-188 | 6 CHANGES_REQUESTED | 381 + 30 skipped QML | lead `0.0.42` ok |
| 2026-11-06 | 372fa87..handoff | T-162 (lead) | 5 defects found by the VM check in my own work | 381 + 30 skipped QML | `0.0.44-t162`: smoke, session 45, devices 57, ISO ok; session check also 45 PASS on the Dell |
| 2026-11-06 (build loop) | handoff..653c8ed | T-189, T-192, T-193, T-191, T-196, T-195 merged; T-200 reviewed pending; T-214 running | 3 CHANGES_REQUESTED (T-191 test order, T-196 wrong "profile data" claim, T-189/T-195 non-blocking); lead fixes: library trap, ISO guard, slim-script protections | 403 QML + 33 skipped (T-196), 420 + 38 (T-200 branch) | image `0.0.47-combined` built; ISO/VM checks pending |

Older rows: git history of this file.
