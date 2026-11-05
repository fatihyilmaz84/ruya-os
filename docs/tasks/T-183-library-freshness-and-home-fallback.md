# T-183 — Library stays fresh and Home never says "empty" over installed apps

Status: todo · Phase: 2 · Depends: — · Area: services, shell · Size: M · Owner: builder

## Goal
Three small T-163 findings about the library: it rescans when a Flatpak app is renamed or recategorised (not only added or removed), Home does not say "Your library is empty" while apps are installed but none has been played, and Flatpak titles use the real app name instead of the id-derived placeholder ("TestGame").

## Read first
- `docs/tasks/T-163-ruya-library-in-the-image.md` Outcome; `services/ruya-library/src/watch.rs` (`fingerprint` is names only), `main.rs`
- `api/dbus/org.ruyaos.Library1.xml`; `shell/src/library/`; `shell/qml/HomePage.qml` (empty state, Recent row) and `GamesPage.qml`
- `services/CLAUDE.md`, `shell/CLAUDE.md`

## Scope
1. **Fingerprint:** include each deployed app's deploy commit (Flatpak's `active` symlink target or the `deploy` file) with its name, so a changed app triggers a rescan without pressing Rescan.
2. **Titles:** when a Flatpak's metadata has no name, read it from the exported `.desktop` file `Name=` or the app's appstream data (installed `metainfo`), before falling back to the id. Say which source you used and why.
3. **Home:** when the Recent row is empty (nothing has `last_played`) but the library has installed items, Home shows the installed ones (the order the Games page uses) instead of the empty state. The empty state stays only for a library with nothing installed. Extend the contract if you need a field (XML, service, mock, D-Bus client together).

## Out of scope
- Recording `last_played` on launch (T-147), `Rescan` UI, cover-art changes.

## Acceptance criteria
- [ ] Rust tests: the fingerprint differs when only an app's deploy commit changed (fails with the names-only fingerprint); a metadata-less app gets its `.desktop` / metainfo name.
- [ ] `tst_home.qml`: with installed items and no `last_played`, Home shows them and not the empty state; with no items it still shows the empty state. Focus lands on the first card.
- [ ] A screenshot (`dev.ps1 shots`) of Home with installed-but-unplayed apps, read against `04` §8.
- [ ] VM (lead run): extend `scripts/vm-library-check.sh`: update an installed Flatpak and see the library change without `Rescan`. Outcome: `Verified: host (vm pending: vm-library-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- `03-services-and-apps.md` library section; `02-shell.md` Home empty state.

## Hints
- Don't build an image.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
