# T-365 - Sound for profile apps: a pulse socket per profile (B-007, ADR-010)

Status: in-progress · Phase: 2 · Depends: T-340 · Area: image (user unit, PipeWire config, tmpfiles), services (ruya-session) · Size: M · Owner: lead · Developer surface: internal

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
- [ ] Rust tests: `an_app_gets_its_profiles_pulse_server`, `the_pulse_server_is_started_before_the_app`, `a_failed_pulse_start_still_launches_the_app` (red when removed).
- [ ] VM (this task): `vm-session-check.sh check` asserts the socket directory's mode and ACL, that `ruya-p1` can connect and another user cannot, and that the server's config refuses module loading; `RUYA_BOOT_OK`.
- [ ] hw: SuperTuxKart launched through the shell on the Dell has an output stream owned by `ruya-p1`.

## Outcome
_Filled in by the implementer._

Feasibility (lead-7, Dell 0.0.58, by hand): a `pipewire-pulse` run in `ruya-shell`'s manager with `PULSE_RUNTIME_PATH=/run/ruya-pulse/ruya-p1` (directory 0700 + `u:ruya-p1:x`): `ruya-p1` connects, `nobody` gets EACCES; STK run as `ruya-p1` with `PULSE_SERVER=unix:/run/ruya-pulse/ruya-p1/native` loads its sounds and shows in `pw-dump` as an output stream of user `ruya-p1`. The second server logs "D-Bus name org.pulseaudio.Server already taken" (harmless).
