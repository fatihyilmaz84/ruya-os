# T-365 - Sound for profile apps: a pulse socket per profile (B-007, ADR-010)

Status: done · Phase: 2 · Depends: T-340 · Area: image (user unit, PipeWire config, tmpfiles), services (ruya-session) · Size: M · Owner: lead · Developer surface: internal

## Goal
A game launched from the shell plays sound. On the Dell SuperTuxKart said "Could not open the default sound device": profile users run no PipeWire (ADR-010) and nothing gave them the shell's.

## Read first
- `docs/specs/00-overview.md` ADR-010, ADR-023; `docs/specs/03-services-and-apps.md` (launching apps); `image/CLAUDE.md`, `services/CLAUDE.md`
- `services/ruya-session/src/spawner.rs` (`app_env`), `systemd.rs`, `main.rs`; `image/rootfs/usr/lib/systemd/user/`

## Scope
1. **Image:** a user unit `ruya-pulse@.service` in `ruya-shell`'s manager (instance = the profile's Unix user, `ruya-<id>`): it makes `/run/ruya-pulse/ruya-<id>` (0700, owned by `ruya-shell`, one ACL entry `user:ruya-<id>:--x`) and runs a second pulse server (`pipewire -c ruya-profile-pulse.conf`, `PULSE_RUNTIME_PATH` = that directory) against the shell's PipeWire. The config refuses module loading (`pulse.allow-module-loading = false`) and loads none of the pulse.cmd helper modules. `/run/ruya-pulse` (0711, `ruya-shell`) from tmpfiles.
2. **ruya-session:** before an app starts, start `ruya-pulse@<user>.service` in `ruya-shell`'s manager (failure is logged, the app still starts without sound) and give the app `PULSE_SERVER=unix:/run/ruya-pulse/<user>/native`; `flatpak run --socket=pulseaudio` binds exactly that socket into the sandbox.
3. **ADR-010** and `03` describe what is built.

## Out of scope
- Per-profile levels on app streams (`ambient`/`media`, rest of B-007), stopping a deleted profile's server (it is unreachable and ends with the shell's session), microphone privacy (T-220).

## Acceptance criteria
- [x] Rust tests: `an_app_gets_its_profiles_pulse_server`, `the_pulse_server_is_started_before_the_app`, `a_failed_pulse_start_still_launches_the_app` (red when removed).
- [x] VM (this task): `vm-session-check.sh check` asserts the socket directory's mode and ACL, that `ruya-p1` can connect and another user cannot, and that the server's config refuses module loading; `RUYA_BOOT_OK`.
- [x] hw: SuperTuxKart launched through the shell on the Dell has an output stream owned by `ruya-p1`.

## Outcome
Verified: vm (0.0.59) + hw (Dell 0.0.59; audible sound to be confirmed by the owner at the TV)

Built (lead, Opus 5.5, 2026-11-09): `image/rootfs/usr/lib/systemd/user/ruya-pulse@.service` (a second pulse server per profile user in `ruya-shell`'s manager: `+install -d -m 0700` and `+setfacl -m u:%i:x` before the server starts, `pipewire -c ruya-profile-pulse.conf` with `PULSE_RUNTIME_PATH=/run/ruya-pulse/%i`, `ExecStartPost` waits for the socket, `TimeoutStartSec=5s`), `image/rootfs/usr/share/pipewire/ruya-profile-pulse.conf` (only `unix:native`, `pulse.allow-module-loading = false`, no `pulse.cmd`, no D-Bus name), tmpfiles `/run/ruya-pulse` 0711 `ruya-shell`; `ruya-session`: `Spawner::start_sound` (blocking `systemctl --user --machine=ruya-shell@.host start ruya-pulse@<user>.service`, child killed after 10 s), `Session::with_pulse_dir` (production only), `spawner::pulse_server`/`with_pulse_server`/`pulse_start_command`; the launch env check now allows `:` (without it every launch with `PULSE_SERVER=unix:...` would have failed: found by `an_app_gets_its_profiles_pulse_server`). ADR-010 and 03 describe it.

Tests: `an_app_gets_its_profiles_pulse_server`, `the_pulse_start_command_names_only_a_profile_users_instance`, `the_pulse_server_is_started_before_the_app`, `a_failed_pulse_start_still_launches_the_app` (the reviewer's revert of the `start_sound` call turned the two session tests red). `cargo test -p ruya-session` 119 passed, Linux clippy clean.

VM 0.0.59 (fresh disk, `-Audio`): `RUYA_BOOT_OK 0.0.59`; `vm-session-check.sh check` 37 PASS; `display` 37 PASS including the new block (PULSE_SERVER in the app unit, `ruya-pulse@ruya-p1` active, `/run/ruya-pulse` 0711 ruya-shell, ACL `user::rwx user:ruya-p1:--x group::--- mask::--x other::---`, ruya-p1 connects, the second profile gets PermissionError, the server runs `ruya-profile-pulse.conf`). The 0.0.59 image predates the start bound (`ExecStartPost`, `TimeoutStartSec`, the 10 s child limit): checked by hand on the Dell (start 295 ms, socket present on return), in the image from 0.0.60.

hw (Dell 0.0.59): p1 signed in over `Profiles1.SwitchTo`, `Session1.Launch` of SuperTuxKart: `ruya-pulse@ruya-p1` active, the sandbox sees `PULSE_SERVER=unix:/run/flatpak/pulse/native`, `pw-dump` shows a running `Stream/Output/Audio` of `supertuxkart` owned by `ruya-p1`; no "Could not open the default sound device". Earlier by hand on 0.0.58 the same with `nobody` refused.

Review (ruya-reviewer, APPROVE): the start bound and "started means listening" were done after it; open notes are Inbox lines (profiles are full-rights clients of the shell's PipeWire; a real `load-module` attempt in the VM check). Also fixed on this branch, for T-340: the bridge address is built with zbus's typed `Unixexec` (zbus does not percent-decode unixexec arguments; the escaped address made every bridge fail; VM restart check passes with the fixed binary).

Feasibility (lead-7, Dell 0.0.58, by hand): a `pipewire-pulse` run in `ruya-shell`'s manager with `PULSE_RUNTIME_PATH=/run/ruya-pulse/ruya-p1` (directory 0700 + `u:ruya-p1:x`): `ruya-p1` connects, `nobody` gets EACCES; STK run as `ruya-p1` with `PULSE_SERVER=unix:/run/ruya-pulse/ruya-p1/native` loads its sounds and shows in `pw-dump` as an output stream of user `ruya-p1`. The second server logs "D-Bus name org.pulseaudio.Server already taken" (harmless).
