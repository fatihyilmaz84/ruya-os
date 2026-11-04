# T-169 — `dev.ps1 test` works first time in a fresh worktree and after a merge

Status: in-progress · Phase: 2 · Depends: — · Area: scripts · Size: S · Owner: builder

## Goal
Every builder lane starts in a fresh worktree, and every merge can add `.qml` files. Today both cost a red `test` and a manual fix. After this task, `.\scripts\dev.ps1 test` goes green on the first run in both cases, without hand-run commands.

## Read first
- `scripts/dev.ps1` (the build step, the translation-lint step at about line 170, how CMake is found)
- `scripts/lint-translations.ps1`, `scripts/lint-tokens.ps1`
- `docs/dev-setup.md` (build section)

## Scope
1. **Translation lint in a fresh worktree:** `dev.ps1 test` fails until the `update_translations` target was built once. Make `dev.ps1` build what the lint needs itself (or make the lint independent of that first build), so a fresh `git worktree add` + `dev.ps1 test` is green.
2. **Stale lupdate project after a merge:** when a merge adds a `.qml` file, `shell\build-win\.lupdate\ruya-shell_lupdate_project.json` keeps the old source list and the lint reports the new strings as "vanished". Reconfigure (`cmake -S shell -B shell\build-win`) when `shell/CMakeLists.txt` is newer than that file.
3. **The right CMake:** devkitPro's `cmake` (and `git`) come first on this host's PATH and can't use the Visual Studio generator. `dev.ps1` must call the Visual Studio/`%ProgramFiles%\CMake` one explicitly, as it does for Qt tools. Don't change PATH system-wide.
4. **Token-lint self-check output:** it prints the deliberately bad sample (`Bad.qml:1: Text { font.pixelSize: 30 * u }` and "Move these into Theme.qml tokens…") as if it were a real finding. Print only the `ok: token lint self-check` line unless the self-check fails.

## Out of scope
- Speeding up the first full build (~10 min).
- Any change to what a lint checks.

## Acceptance criteria
- [ ] A fresh worktree (`git worktree add` from Git Bash, then `dev.ps1 test`) ends `ALL GREEN` on the first run, with no extra command; the Outcome pastes the tail of that run.
- [ ] After adding a dummy `.qml` with one `qsTr` string to `CMakeLists.txt` and the `.ts` files in an existing build, `dev.ps1 test` is green without a manual reconfigure (then remove the dummy; describe the run in the Outcome).
- [ ] With PATH as in a normal shell on this host (devkitPro first), the build and translation steps use the right CMake (the Outcome names how `dev.ps1` finds it).
- [ ] The token-lint step prints no `Bad.qml` line when the self-check passes, and still fails when the self-check doesn't (break it temporarily, then restore).
- [ ] `dev.ps1 test` ALL GREEN in the main checkout.

## Docs to update
- `docs/dev-setup.md` (remove any manual step this makes unnecessary).
- `docs/LEAD.md` 4b (the `.ts` merge recipe can drop its reconfigure step) and the host notes the lead gives builders.

## Hints
- In the PowerShell tool `git` is devkitPro's MSYS2 build: run git from the Bash tool.
- The lupdate project path is `Join-Path $ShellBuild ".lupdate\ruya-shell_lupdate_project.json"`.

## Outcome
Verified: host

**Before** (this worktree, fresh, base 3f2f787): `dev.ps1 test` built everything, then ended `FAILED: translation lint` ("lupdate project not found ... .lupdate\ruya-shell_lupdate_project.json (build the shell first)"); the token lint printed the `Bad.qml:1: ...` sample.

**What really fixes scope item 2.** The task text said "reconfigure"; that is not enough. Configure only writes `.lupdate\ruya-shell_lupdate_project.<Config>.cmake` (with the source list); the `.json` that `lupdate` reads is written by the build's `ruya-shell_lupdate` target (the one `update_translations` runs, which also rewrites the tracked `.ts`). `dev.ps1` now has `Update-LUpdateProject`: when the json is missing or older than `shell\CMakeLists.txt` it reconfigures (only if the `Release.cmake` is also older than CMakeLists) and regenerates the json by running Qt's `GenerateLUpdateProject.cmake` on the `Release.cmake`, the same script that target runs, without touching the `.ts` files.

**After:**
1. Fresh worktree (`git worktree add`, then `dev.ps1 test`, first run, no other command), tail: `Totals: 299 passed, 0 failed, 26 skipped, 0 blacklisted` / `ok: Qt Quick tests` / `ALL GREEN (test)`.
2. Existing build, green; then added `qml/Dummy169.qml` (one `qsTr`), listed it in `CMakeLists.txt` and added its entry to both `.ts` by hand, touched CMakeLists: `dev.ps1 shell` ended `ALL GREEN (shell)`; the regenerated json contained `Dummy169`. Dummy removed afterwards. (Before the change, the same state is the lead's observed "vanished" failure.)
3. CMake: `Find-CMake` takes `%ProgramFiles%\CMake\bin\cmake.exe`, else Visual Studio's bundled one, else PATH, and `dev.ps1` calls it explicitly (`& $script:CMake`) and puts its folder first on PATH for MSBuild. Run with devkitPro first on PATH (this host's normal shell): used `C:\Program Files\CMake\bin\cmake.exe`. `dev.ps1 check` prints the chosen path.
4. Token lint: the pass run prints only `ok: token lint self-check`; with the fixture changed to clean text (temporary, extracted function) it printed `FAILED: token lint self-check`.
5. Full `test` ALL GREEN ran in the fresh worktree of this branch (includes Rust, lints, Qt tests); not run in the main checkout, which the lead merges into.

Files: `scripts/dev.ps1`, `docs/dev-setup.md`, `docs/LEAD.md` (4b `.ts` recipe: reconfigure step dropped). No `lint-*.ps1` changed. Not changed: `Status:`, STATUS.md.
