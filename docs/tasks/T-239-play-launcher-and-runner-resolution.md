# T-239 — Launcher and runner resolution: bundled, system or newest

Status: todo · Phase: 7 · Depends: T-229, T-238 · Area: services, shell, image · Size: M · Owner: lead

## Goal
An installed `.play` starts: the launcher reads the manifest, picks the Wine (or native, or engine) it should use by the package's `source` rule and the player's override, prepares the per-profile Wine prefix, runs first-run setup once, and execs the program inside the sandbox. The player can see and change which runner is used.

## Read first
- `docs/specs/05-play-packages.md` §6 (all), §10; T-229 Outcome (display path, Xwayland or Wine Wayland), T-238 Outcome
- `T-233`'s resolution function (shared code), `docs/specs/03-services-and-apps.md` §4.1 (launch modes), 02 §4 (Guide button, quick menu)

## Scope
1. `ruya-play-launch` (a small Rust binary shipped in the `org.ruyaos.Play.Launcher` extension): reads `/app/play.json`, validates it again with the same crate (it is untrusted data even after install), resolves components with the shared pure function, builds the argv/env with the allow-list and placeholders of 05 §6.3, creates the prefix from the template once, runs `setup[]` once per prefix with a timeout and a status the splash can show, then `exec`s. No shell, no string commands.
2. Runner discovery: system runners are read from extensions' `runner.json` (T-244 provides the first); versions compared within a family only; `max_major` fence; clear failure when nothing satisfies (the sentence the shell shows).
3. **Compatibility screen** (shell, from the app's Options): shows runner in use, bundled/system versions, `tested`, and "Package default / Bundled / System" with the choice stored per profile in the app's `config/`; "Try the bundled runner" offered after a `crashed` exit of a package that has one.
4. Prefix `epoch` migration (05 §6.3): back up `data.saves` paths, recreate, restore; tested with a fake runner.
5. Launch modes `fullscreen|gamescope|default` mapped like `x-ruya-launch-mode`.

## Out of scope
- Building the Wine runner extension (T-244), Proton, emulators, permission mapping beyond what T-238 generated (T-240).

## Acceptance criteria
- [ ] Host tests of the launcher core with a fake filesystem: every `source` mode against the matrix of (bundled present/absent) x (system present/absent/older/newer/major above `max_major`) gives the documented runner or error (`tests/resolve.rs`, table-driven, one row per case); env allow-list rejects `LD_PRELOAD`, `PATH`, `XDG_DATA_HOME`, `FLATPAK_ID`; argv placeholders substitute only the named ones; setup runs once and not again; failed setup is reported (`tests/launch.rs`).
- [ ] Shell tests: the Compatibility screen lists the right choices for fixtures, stores the override, offers the bundled runner after a crash (`tst_compat.qml`); screenshots English and Turkish reviewed.
- [ ] VM (lead run): `scripts/vm-play-check.sh launch`: a fixture Windows program (a tiny PE built with a cross-compiler into the test image, or the freeware sample chosen in T-229) starts under the system Wine, writes its save into the prefix, survives a relaunch, and uses the bundled runner when the player's override says so; the Guide key over the running game works (needs T-164/T-147 status in the Outcome).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```
Then the VM check (lead run).

## Docs to update
- Spec 05 §6, §10 as built; `docs/developers/` gets the runner chapter content in T-243.

## Outcome
_Filled in by the implementer._
