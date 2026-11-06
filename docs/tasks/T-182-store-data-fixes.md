# T-182 — Store data fixes: developer name once, installed state follows Flatpak

Status: done · Phase: 2 · Depends: — · Area: services · Size: S · Owner: builder

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
- [ ] VM (lead run): extend `scripts/vm-store-check.sh` with: install an app, `flatpak uninstall` it, Install again is accepted. Outcome says `Verified: vm (lead, image `0.0.42-lead`, 2026-11-06): `vm-store-check.sh check` 67 PASS, 0 FAIL, including the new section (an app removed with `flatpak uninstall` can be installed again: `ss "ok" "job-5"`). Earlier: host`.
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
Verified: host (vm pending: vm-store-check.sh)

**Developer name once.** `appstream.rs`: `<developer_name>` now goes into its own `Builder.developer_name`; `<developer><name>` fills `developer` as before; `finish()` uses `developer_name` only when `developer` is empty. Translated variants stay ignored. Test `the_developer_is_named_once_whichever_elements_carry_it` covers both elements (either order), each alone, none, and a translated `developer_name`. Revert check: restoring `b.c.developer.push_str` for `developer_name` fails it ("both: the current element").

**Installed state follows Flatpak.** `service.rs`: new `Store::sync_installed()` runs `flatpak list` (the existing `Flatpak::installed()`) and corrects every catalogue entry's `installed` flag (and clears `update_available` for one that is gone). It runs at the start of `queue()` (so `Install`, `Uninstall`, `Update` and `Rollback`, after id validation) and in `list_installed()`. Why this and not a TTL or event invalidation: it is correct at the moment the answer is given and costs one `flatpak list` next to calls that already start a transaction or read remotes; a TTL leaves a window of wrong answers and a watcher is more machinery than the task asks for. A failing `flatpak list` keeps the catalogue as it was. The `flatpak` call happens before the state lock is taken. `FakeFlatpak::remove_installed` simulates `flatpak uninstall` by hand. Tests: `an_app_removed_outside_the_store_can_be_installed_again` (installed, `already-installed`, removed outside, `ListInstalled` empty, `Install` accepted, and `Uninstall` of an app removed outside gives `not-installed`) and `install_is_accepted_after_an_outside_removal_even_without_a_list_call`. Revert check: removing the two `sync_installed()` calls fails both.

**Round 2 (review: a correction swallowed a job's `InstalledChanged`).** In round 1 `refresh()` compared the new catalogue with `state.catalogue`, which `sync_installed` also wrote. A query arriving after a job's `flatpak install` returned but before its `refresh()` finished pre-applied the change, `refresh()` returned `Ok(false)` and no `InstalledChanged` went out. Fix: `State.announced` holds the installed set and update flags last announced; only `refresh()` compares against it and updates it; `sync_installed` never touches it. Second fix: `State.generation` is bumped by every `refresh()`; `sync_installed` remembers it before running `flatpak list` and drops its result if a refresh finished meanwhile (a stale read cannot undo a newer catalogue). `FakeFlatpak` got `set_installed_fails` and `after_next_installed` (a hook run once after the next `installed()` read) for the tests. Tests and reverts: `a_job_that_ends_during_a_query_still_sends_installed_changed` (reverting to comparing with `state.catalogue` fails it: `refresh()` gives `Ok(false)`), `a_list_read_overtaken_by_a_refresh_is_dropped` (removing the generation check fails it), `a_failing_flatpak_list_keeps_the_installed_flags` (treating a failed read as an empty list fails it). A correction still announces nothing itself: the lead said to do that only if small, and it would need a "changed" flag through the D-Bus layer; left as the follow-up below. Not changed: the D-Bus handlers still run these blocking reads on the bus thread (the lead has that in the Inbox).

**VM check (not run, lead run).** `scripts/vm-store-check.sh` has a new last section "removed outside the Store (T-182)": after the T-171 restart section it waits for the catalogue, installs the app, expects `already-installed` on a second Install, `flatpak uninstall` by hand, expects `ListInstalled` to be empty and `Install` to be accepted and to finish ok, then cleans up. It starts its own `busctl monitor` on a truncated `signals.log` because job ids restart after the service restart. Only `bash -n` was run here.

Files: `services/ruya-store/src/appstream.rs`, `service.rs`, `flatpak.rs`, `scripts/vm-store-check.sh`, `docs/specs/03-services-and-apps.md` (Store "As built" paragraph).

Deviations: none. Follow-up (Inbox): a correction made by `sync_installed` sends no `InstalledChanged`, so a shell that had the app listed as installed keeps showing it until its next read; it learns from the `ListInstalled`/`Install` answer only if it asks.
