# T-220 — Privacy settings and what each app may access

Status: todo · Phase: 3 · Depends: — · Area: shell, services · Size: M · Owner: builder · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Two permission layers, each with one owner: Flatpak overrides (sandbox level, per console) in `ruya-store`, built here and reused by T-240; capability grants (per profile) in ruya-platform's table (T-352), shown in this pane by a later step that depends on T-352. Scope 2b's "mDNS/avahi is removed" is stale: ADR-029 brings Avahi back for Ruya Web, and the network-visibility text must name Ruya Web when it is on.

## Goal
Settings -> Privacy tells the player plainly what the console shares and lets them control what apps can reach. Owner request, 2026-11-06: "privacy settings". A console is a shared family device, so privacy has three parts: what the console itself sends out, what is visible to others on the network or to other profiles, and what each app may access.

## Read first
- `docs/specs/03-services-and-apps.md` §4.4 (permissions: the Store shows them in plain words, `High risk` flags for `all-devices`, `host-files`, `session-bus`), `§4.5a` (profile data is private), the spec's security/threat paragraphs in `01-platform.md` §3, `docs/specs/00-overview.md` (no telemetry statements, if any: grep "telemetry")
- Flatpak overrides (`flatpak override --system [--nosocket=pulseaudio|--unshare=network|--nodevice=all]`, the metadata and the overrides file `/var/lib/flatpak/overrides/<id>`), the portal permission store (`org.freedesktop.impl.portal.PermissionStore`) for camera/microphone/location decisions, `services/ruya-store` (permission reading `GetApp.permissions`, `new_permissions`), `AppDetailPage.qml` permission list
- `docs/tasks/T-216` (network name, DNS over TLS), `T-211` (parental controls: not this task)

## Scope
1. **State the policy (spec text, owner-visible), consistent with telemetry (T-224/T-225, owner decision 2026-11-06):** the console sends **nothing about the user or the hardware until the user has chosen**; with consent it sends hardware information and crash reports (closed schemas, no identifiers beyond a random resettable ID, never names, addresses or files); each category can be turned off at any time, which deletes what is queued; the only other outgoing connections it makes by itself are the update check (`bootc`), the store catalogue and Flathub/appstream refresh, NTP and the connectivity check; no advertising, no accounts. Write this in `docs/specs/01-platform.md` (a "Privacy" section that links to the Telemetry section) and show the same plain text on Settings -> Privacy and About. (Owner confirms the wording together with the privacy notice of T-224.)
2. **Settings -> Privacy (shell):** (a) the statement above and, from T-224, the "Help improve RuyaOS" switches (this task only reserves the place and the statement: T-224 builds the controls); (b) **Network visibility**: whether the console answers discovery on the local network (mDNS/avahi is removed from the image by T-195: state "off"), and the device name (link to T-216); Bluetooth visibility ("The console is only discoverable while you pair a device", true by design); (c) **App permissions**: a list of installed apps (reuse T-221's list if it exists) with what each can access in plain words (network, sound, microphone, camera/other devices, files, the internet, run in the background), the high-risk ones marked; (d) **Toggles per app, admin only, where Flatpak can enforce them reliably:** Network (`--share=network`/`--unshare=network` override), Microphone (the audio socket or the capture portal permission), Other devices (cameras and USB devices); each applies at the next launch, shows "Takes effect next time you open it", and the override file is the single source (the page re-reads it); "Reset to the app's defaults" removes the override; (e) **Your activity**: "Clear my play history" (recent items and last-played of the active profile only, with a confirmation; the profile's own data only) and "Hide my activity from other profiles" if recents are visible across profiles (check; if not, say so and skip).
3. **Service side:** `ruya-store` (root) gets `GetPermissions(app_id)` (effective permissions after overrides, in the same key vocabulary as `GetApp.permissions`) and `SetPermissionOverride(app_id, key, allow)`/`ResetPermissions(app_id)` (admin only, validated keys, writes through `flatpak override --system`, never edits the metadata); refuses overrides that would add a permission the app did not ask for (an override can only withdraw) and refuses `--filesystem` changes entirely in v1; contract first; pure core with tests.
4. **The microphone and camera reality check:** document which of the camera/microphone permissions can really be enforced today (PipeWire/portal stage) and which not; show only the toggles that work, and a plain "Not controllable yet" note for the rest (honesty over a fake switch).

## Out of scope
- Telemetry and crash-report collection themselves (T-224, T-225), VPN/DNS blocklists (T-216 has DNS), parental controls (T-211), per-profile app permissions (overrides are per console), file-access prompts for portals, location services, ad blocking.

## Acceptance criteria
- [ ] Rust tests (store core): effective permissions with and without overrides, withdrawing a permission works, adding one the app did not request is refused, unknown keys `invalid`, the admin rule, reset removes only our override, the override file format; no shelling out with unvalidated input (argument list tests).
- [ ] `tst_privacy.qml`: the statement and rows show; the permission list marks high-risk entries; an admin toggles Network for an app and the row shows the pending note and re-reads; a non-admin sees the list read-only; Reset works; Clear history only affects the active profile's mock data; focus asserted, controller-only operation; late replies guarded; screenshots (English and Turkish) against `04` §8.
- [ ] VM (lead run): extend `vm-store-check.sh` (or a new small script): an override on the test app withdraws `network`, the app's effective permissions change, `flatpak run` of the test app has no network (check from inside the sandbox), reset restores it; a non-admin caller refused.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `01-platform.md` (Privacy), `03` §4.4, the Store XML, `02-shell.md` (Settings), `docs/developers/` (permissions chapter, T-214: players can withdraw network/microphone, so apps must cope).

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): this pane is where the player sets the per-app permission table of `Platform1` (T-352); keep its model (app, capability, on/off, revoke) generic.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
