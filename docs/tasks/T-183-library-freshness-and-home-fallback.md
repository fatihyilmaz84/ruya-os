# T-183 — Library stays fresh and Home never says "empty" over installed apps

Status: in-progress · Phase: 2 · Depends: — · Area: services, shell · Size: M · Owner: builder

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
Verified: host (vm pending: vm-library-check.sh). `dev.ps1 test` ALL GREEN (356 QML passed, 29 skips, all Rust crates green); `dev.ps1 shots` 70 passed, `01-home-unplayed.png` and `01-home.png` read. The VM check is written, not run (no image built).

**Fingerprint (`watch.rs`).** In addition to the names, every deployed app now contributes, per `app/<id>/<arch>/<branch>`, the target of the `active` symlink and every commit directory that has a `deploy` file. A rename or recategorisation arrives as an update, which is a new commit, so it changes the fingerprint. A commit directory without `deploy` (deployment in progress) is not counted, and hidden directories are skipped (flatpak checks a deployment out into `.<checksum>-XXXXXX` and renames it; test `a_hidden_checkout_directory_is_not_a_commit`, fails without the skip). `file_type` does not follow symlinks, so `current`/`active` are not walked as directories. Tests: an update that only adds a deployed commit changes the fingerprint (undoing the `deployments` loop fails exactly that test, 1 of 40); a half-deployed commit is no change; a unix-only test moves `active` between two commits (Windows host cannot create symlinks without privilege; it compiles and runs on the Linux target only, so it is unverified here).

**Titles (`flatpak.rs`).** `flatpak list` takes the name from the remote's AppStream catalogue and prints the id's last part when it has none (the T-163 "TestGame"), so an empty name column is not the only case: the listed name counts as a placeholder when it is empty or equals the id's last part. Then the exported desktop entry's unlocalized `Name=` is used first (every launchable app has one, it is the name the app calls itself, and the service already reads that file for the kind), then the installed metainfo's `<name>` (`<developer>` block skipped, `<name xml:lang>` translations ignored, other attributes such as `translatable="no"` accepted, `<developer_name>` is not a `<developer>` block; plain text search, not an XML parser; tests `metainfo_name_takes_other_attributes_but_not_translations`, 2 tests fail without the attribute handling), then the listed name or the id. New `AppLister::metainfo` (default `None`; `FlatpakCli` reads `exports/share/metainfo/<id>.metainfo.xml`, `exports/share/appdata/<id>.appdata.xml`, then the app's own `files/share/metainfo`), `FixtureLister::with_metainfo`. A real app whose name equals its last id part (Notes) stays as it is unless a file names it differently. Tests undone: `title_of` returning the listed name, 4 title tests failed.

**Home (`Shell.qml`).** With no `Library.recent` but items installed, the Recent row holds the first eight of `Library.items` (the Games page's order: played first, then by title, then id) and the eyebrow reads "Installed" (translated, `Kurulu`). All installed items count, apps included: `Library.items`, not `games`. The empty state stays for a library with nothing installed. No contract change was needed (no XML, service, or D-Bus client edits); the mock got an `unplayed` scenario (`resetMockForTests("unplayed")`). Tests in `tst_home.qml`: `test_installed_but_unplayed_items_fill_the_row` (Play focus, hero, eyebrow, 8 cards, Down lands on card 0 and it is focused, Right/Return launches the second), `test_played_items_still_win_over_the_installed_fallback`, and `test_empty_library` asserts `Library.items` is empty. Undone: `recentIsFallback` forced to false, the unplayed test failed.

**VM (`scripts/vm-library-check.sh`).** The title assertion is now "Test Game" (the desktop entry's name; the test repository has no AppStream catalogue). New step: (`make_app` now starts with `rm -rf` of its build directory, since `build-finish` refuses a finalized one) rebuilds the test game as "Test Game Reloaded" with `Categories=Utility;`, `flatpak update --system`, then fails loudly unless the installed commit really changed (`flatpak info --show-commit` before and after, and no "Nothing to do"), then waits (no `Rescan`) for the new title, `kind` app and an `ItemsChanged`. `bash -n` passes; not run.

Files: `services/ruya-library/src/{watch,flatpak}.rs`, `shell/qml/Shell.qml`, `shell/src/library/{MockLibraryBackend.cpp,Library.h}`, `shell/tests/tst_home.qml`, `shell/i18n/ruyashell_{en,tr}.ts`, `scripts/vm-library-check.sh`, `docs/specs/02-shell.md`, `docs/specs/03-services-and-apps.md`. Deviations: none.
