# T-355 - Dell smoke test with a real game: SuperTuxKart through the shell

Status: todo · Phase: 2 · Depends: T-386 · Area: hardware test (the Dell), no image change · Size: M · Owner: lead · Developer surface: none

## Goal
Owner OK (2026-11-08): install a real game on the Dell over SSH and run it THROUGH THE SHELL, to find what breaks between the services, the session, the compositor, the audio and the pads. SuperTuxKart (Flathub `net.supertuxkart.SuperTuxKart`) installs into the system Flatpak installation that `ruya-session` launches from (check how the Store installs: same remote and installation, same permission flow). No image change; STK stays installed on the Dell for later tests (it is not part of any image). **BLOCKED on T-164 (2026-11-08, found by the other lead on the Dell):** `Session1.Launch("net.supertuxkart.SuperTuxKart","p1")` answers ok, the unit `ruya-app-ruya-p1-...service` exits after 188 ms with code 1; by hand STK reads its data, then `Unable to initialize SDL!: No available video device`: the profile user cannot reach the compositor's socket (the spawner sets WAYLAND_DISPLAY=wayland-0 but the socket is in ruya-shell's 0700 runtime directory; `docs/developers/fullscreen-and-lifecycle.md:22`). Run this test when T-164 is done; T-164 uses STK as its Dell acceptance. Note: per-profile Wayland sockets (T-164) may not be done: "Play does nothing yet" is itself a finding, record exactly what happens.

**Update 2026-11-08 (lead-5):** the other lead already installed it on the Dell: `flatpak install --system -y flathub net.supertuxkart.SuperTuxKart` (the `flathub` remote there is filtered; STK 1.5 is 831 MB plus runtime `org.freedesktop.Platform` 26.08 (724 MB), GL.default 26.2.5 (470 MB), VAAPI.Intel, codecs-extra; `/var` is 17 GB used of 463 GB). It was not launched or tested. Scope item 1 is the Store-path check and the timing only.

## Read first
- `docs/specs/03-services-and-apps.md` §4.5a (save data), `ruya-session` (T-162, T-290), `ruya-store` install path, `docs/tasks/T-164-per-profile-wayland-sockets.md`, ADR-017 (players), T-313 (ambient hold), T-337 (stuck key), B-003 in STATUS
- The Dell: 192.168.178.109, root with `~/.ssh/ruyaos_dev` (`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`); `docs/dev-setup.md`

## Scope (record each in the Outcome with `Dell: ...` lines; failures become follow-up tasks or Inbox lines)
1. Check free space on the Dell's `/var` first (STK needs about 700 MB plus the runtime). Install over SSH into the system installation; time it and record the disk use; if the Store UI can be driven (`vm-goto.ps1`-style or keys), also try the Store path, else CLI.
2. Launch it through the shell (library entry or Store "Play"), as the profile user, not by hand. Does it start? Wayland or X11/Xwayland (our compositor has no Xwayland: if it needs X11, say so; try `SDL_VIDEODRIVER=wayland` via a Flatpak env override or the game's own option).
3. GPU and frame rate on the UHD 630: settings, a frame-time measure (STK's FPS counter or the shell's `FpsMeter`), and the Guide overlay with glass/blur over the running game (B-003).
4. Controller: DualSense navigation and driving, hotplug, disconnect mid-race (T-337: no stuck key), a second pad joining split screen (ADR-017 test), rumble.
5. Audio: the sink, the ambient bed stops or ducks when an app is in front (T-313), the game's music, volume.
6. Guide overlay over the running game, Resume / Quit / Stop and the kill path (T-162 grace).
7. Suspend/resume with the game running (`rtcwake -m mem -s 30`): picture, audio and pad after resume.
8. Save data under `~/.var/app/net.supertuxkart.SuperTuxKart` per spec 03 §4.5a; per-profile isolation (a second profile does not see the first's data).

## Out of scope
- Fixing what is found (each finding becomes its own task), adding STK to any image, benchmarks beyond a first look.

## Acceptance criteria
- [ ] Every scope item has an Outcome paragraph with what was observed (or "not possible because ...") and the exact commands; the Outcome starts with `Verified: hw`.
- [ ] Each failure is a follow-up task or an Inbox line with the evidence (journal lines, numbers).
- [ ] The Dell look-at list in STATUS gets one line for what the owner should try by hand.

## Verification
Over SSH on the Dell; no repository change except this task file and the follow-ups.

## Outcome
Verified: hw (first pass, lead-6, 2026-11-09, Dell on 0.0.57 with T-164; the owner at the TV). Items 3 (frame times), 4 (hotplug, split screen, rumble), 7 (suspend) and 8 (save isolation) are **not done yet**: the task stays open for a second pass.

- *Item 1:* STK 1.5 was already in the system installation (earlier session); `/var` 442 GB free. Store path not tried.
- *Item 2 (launch):* `runuser -u ruya-shell -- busctl --system call org.ruyaos.Session1 /org/ruyaos/Session1 org.ruyaos.Session1 Launch ss net.supertuxkart.SuperTuxKart p1` (the shell's path) -> `ok`. Native Wayland (SDL 2.32, no X11 needed); the compositor mapped it (`app ... uid 1000 profile p1`, `focus app:supertuxkart true`). Its log: `wayland: Display scaling requires the missing 'zxdg_output_manager_v1' protocol`.
- *GPU:* **software rendering**: `MESA-EGL: failed to get driver name for fd -1`, renderer `llvmpipe (LLVM 22.1.8)`, OpenGL 4.6 Mesa 26.2.5. The sandbox has `/dev/dri/renderD128` (`devices=all`): the compositor advertises no GPU device to clients (no `linux-dmabuf-v1`/`wl_drm`; Fedora's Qt has no compositor dmabuf plugin, B-003). STK used 560 % CPU (of 6 cores), the shell 28 %. Owner: "I can play the game smoothly (but at a low resolution)".
- *Item 4 (first look):* DualSense menu navigation works (owner).
- *Item 5 (audio):* no sound: `MusicManager: Could not open the default sound device`, OpenAL `AL_INVALID_OPERATION`; the profile user has no sound server (`/run/user/1000/pulse` missing, B-007). Separately the system sink was at volume 0.00 (the owner had turned it down).
- *Item 6 (Guide, stop):* Guide opens the System panel over the game and Close returns to it (owner). `Session1.Stop` ended STK in 1 s (SIGTERM, `Finished with result: success`, `app gone`). The unit's accounting shows 28 ms CPU and 3.8 MB: the game runs in Flatpak's own `app-flatpak-net.supertuxkart.SuperTuxKart-*.scope`, not in `ruya-app-*`.
- Follow-ups are Inbox lines in STATUS (lead-6): compositor GPU buffers, profile audio, xdg-output, the scope.
