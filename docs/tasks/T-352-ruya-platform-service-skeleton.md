# T-352 - ruya-platform: the one door for sandboxed apps (caller identity, permission table, rate limits)

Status: blocked · Phase: 7 · Depends: T-250, T-351 · Area: services, api, image, docs · Size: M · Owner: lead · Developer surface: public-API

**Blocked on the owner:** ADR-022 (Proposed, `docs/specs/00-overview.md`) must be accepted, with the tier-B list approved, and decided together with ADR-015 (T-250). Do not start before. Unblocks the app-facing capability tasks (T-245, T-246, T-279, T-304/T-306).

## Goal
A sandboxed app has exactly one bus permission, `--system-talk-name=org.ruyaos.Platform1`, and through it can reach only the capabilities the player allowed. This task builds the empty door and the first interface (Lifecycle); the other capabilities plug in through the same skeleton.

## Read first
- ADR-022, `docs/developers/api-surface.md`, `docs/specs/03-services-and-apps.md` §4.4, `api/dbus/org.ruyaos.Session1.xml` (apps, instances, the 5 s stop)
- `services/ruya-profiles` (reference service), `image/CLAUDE.md` and `services/CLAUDE.md` (units, bus policy, hardening), T-220 (the permission settings UI), T-279 (lifecycle)

## Scope
1. **Spike first (half a day, record in the Outcome):** on the VM, can a root service on the system bus map a caller behind `xdg-dbus-proxy` to its Flatpak app id and instance (the way the session-bus portals read `.flatpak-info`)? If not, write the fallback (a per-app session-bus portal in front of the same core) into ADR-022 and stop for the lead.
2. **Crate `services/ruya-platform`** (pure core, then D-Bus; like `ruya-profiles`): caller identity -> (app id, profile uid) from the connection, never an argument; a permission table per (profile, app, capability) in `/var/lib/ruyaos/platform/` (root-only, atomic writes; default off for sensitive capabilities, on for lifecycle); a token bucket per caller; string and size sanitising helpers; a registry that internal services plug into.
3. **Contract** `api/dbus/org.ruyaos.Platform1.xml`: the first interface `org.ruyaos.Platform1.Lifecycle` (signals `Suspend`, `Resume`, `Stopping(deadline_ms)`, method `SaveDone()`), each element tagged `org.ruyaos.Stability=experimental` and `Since=0`. Also the shell-only management interface (list and set permissions) that the T-220 pane uses; it is **not** tagged public.
4. **Image:** a unit with the standard hardening, a bus policy that lets any caller reach `Platform1` (the service decides) but only the shell and root reach the management interface; the `systemd-analyze security` score as for the other services.
5. **Developer side:** a paragraph in `fullscreen-and-lifecycle.md`; the sample (T-353) gains a lifecycle call.

## Out of scope
- The other capabilities (each is its own task using this skeleton); the Settings UI (T-220); the SDK packaging (T-250/T-251).

## Acceptance criteria
- [ ] Rust tests: identity from the connection; permission off gives `not-allowed`; rate limit; oversized and malformed input rejected; app A cannot act as B; inactive profile; table atomicity and modes; deletion with the profile.
- [ ] Conformance test (abuse cases) runs in `dev.ps1 test`; the `ruya-api-reviewer` verdict is in the Outcome.
- [ ] VM (this task): `scripts/vm-platform-check.sh`: a Flatpak test app as a profile user calls `Lifecycle` through the proxy; permission off is refused; `systemd-analyze security` OK; the app cannot reach any shell-only service.
- [ ] `lint-dev-docs.ps1` (T-350) passes with the tagged elements documented.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the VM check (`scripts/build.sh`, `make-disk.sh`, `scripts\smoke-test.ps1`).

## Docs to update
- ADR-022 status, `03` §4.4 and a new section, `api-surface.md` ("What is public today"), `fullscreen-and-lifecycle.md`, `dev-setup.md`.

## Hints
- Owner is `lead` because the identity mapping and the bus policy are security-critical.
- Missing today for every other capability: its doc paragraph, mock and sample; this task provides Lifecycle only, T-353 the harness.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
