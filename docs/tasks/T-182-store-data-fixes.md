# T-182 — Store data fixes: developer name once, installed state follows Flatpak

Status: in-progress · Phase: 2 · Depends: — · Area: services · Size: S · Owner: builder

## Goal
Two things the 0.0.40 try-out and the T-163 review found in `ruya-store`: a Store card shows the developer name twice ("divVerentdivVerent"), and the Store answers `already-installed` for an app that was removed outside the Store (`flatpak uninstall`) because its installed-apps cache is stale.

## Read first
- `services/ruya-store/src/appstream.rs` around line 186: `developer_name` and `<developer><name>` both `push_str` into `b.c.developer`; newer appstream files carry both elements with the same text
- `services/ruya-store/src/` where the installed set is cached and `Status::AlreadyInstalled` is decided (`app.rs`, the install path); `api/dbus/org.ruyaos.Store1.xml`; `services/CLAUDE.md`
- Reference tests: the existing appstream parser tests and the install-flow tests in the crate

## Scope
1. **Developer name once:** when an appstream component carries both `<developer_name>` and `<developer><name>`, the result is the text once (prefer `<developer><name>`, the current element; fall back to `developer_name`). Translated variants stay ignored as today.
2. **Installed cache:** before answering `already-installed` (and when listing installed state), check against Flatpak's real state, or invalidate the cache when the installation changes (cheapest correct way: re-read installed refs when `Install` is called and when a state query is older than a few seconds; pick one and say why). An app removed with `flatpak uninstall` can be installed again from the Store without restarting the service.

## Out of scope
- Resuming jobs after a service restart (T-188), appstream names for Flatpak titles in the library (T-183), shell changes.

## Acceptance criteria
- [ ] Rust tests: an appstream snippet with both elements gives one developer name (fails if either `push_str` is restored); with only one of the two it gives that one.
- [ ] A Rust test (fake installed-state source, as the crate already fakes Flatpak) shows: installed, then removed outside the Store, then `Install` is accepted instead of `already-installed`.
- [ ] VM (lead run): extend `scripts/vm-store-check.sh` with: install an app, `flatpak uninstall` it, Install again is accepted. Outcome says `Verified: host (vm pending: vm-store-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `03-services-and-apps.md` Store section if the caching rule is described; nothing else.

## Hints
- Don't build an image: the lead runs the VM queue.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
