# T-380 - Profiles apart in the audio graph: what a profile's app may see and change in PipeWire

Status: todo · Phase: 2 · Depends: — · Area: image (PipeWire/pulse config), services (ruya-devices audio), docs · Size: M · Owner: lead · Developer surface: internal

## Goal
A profile's app plays sound and sets its own stream volume, but cannot list, mute or move the shell's or another profile's streams, load modules, or record a sink monitor.

## Read first
- T-365 Outcome and its review (each `ruya-pulse@ruya-<id>` is a full-rights client of the shell's PipeWire today)
- `docs/specs/03-services-and-apps.md` (audio), ADR-010, B-007, T-220
- PipeWire access control: `access.*` rules in `pipewire-pulse` and the client permission model (`pw_client.update_permissions`), `module-protocol-pulse` `server.address` and `pulse.rules`

## Scope
1. Decide the model (a lead decision inside ADR-010; record it as an Accepted (lead) note there): restricted clients with permissions limited to their own nodes plus the default sink, or a per-profile filter sink linked by the shell side.
2. Implement it in the image's PipeWire/pulse config (and `ruya-devices` if it must grant per-node permissions).
3. Extend `vm-audio-check.sh` (or `vm-session-check.sh display`) with real refusals as the profile user: `pactl load-module` refused, `pactl list sink-inputs` shows none of the shell's streams, recording a monitor source fails; the profile's own playback still works.

## Out of scope
- `ambient`/`media` levels on app streams (B-007 remainder).

## Acceptance criteria
- [ ] VM (this task): the new refusal steps PASS and the existing `vm-audio-check.sh` and `vm-session-check.sh display` steps still PASS; `RUYA_BOOT_OK`.
- [ ] Spec 03 says what a profile's app may do in the audio graph.
- [ ] `dev.ps1 test` ALL GREEN.

## Hints
- Today's VM check only greps the shipped config; the new one must act as the profile user.

## Outcome
_Filled in by the implementer._
