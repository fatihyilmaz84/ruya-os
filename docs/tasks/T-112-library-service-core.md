# T-112 — ruya-library: game/app discovery core (Rust)

Status: done · Phase: 5 · Depends: — · Area: services, api · Size: M

## Goal
A Rust service crate that finds installed games and apps (Steam games from Steam's library files; installed Flatpak apps) and serves them as one list over `org.ruyaos.Library1`. All parsing is pure and unit-tested on Windows.

## Read first
- `docs/specs/03-services-and-apps.md` §5 (Library row: Steam `libraryfolders.vdf` / `appmanifest_*.acf`, read-only; launch via `steam://rungameid/<id>`)
- `services/CLAUDE.md` and the whole of `services/ruya-profiles/` as the template
- `api/dbus/org.ruyaos.Profiles1.xml` for contract style

## Scope
1. `api/dbus/org.ruyaos.Library1.xml`:
   - `ListItems() → aa{sv}`. Each item has `id`, `kind` (`game|app`), `title`, `source` (`steam|flatpak`), `launch` (an opaque launch spec string), `art` (dict; may be empty) and `last_played` (unix seconds, 0 if unknown).
   - `Rescan()` and signal `ItemsChanged()`.
2. Crate `services/ruya-library` (add it to the workspace):
   - `vdf.rs`: a parser for Valve's text KeyValues (VDF) format, with nested objects, quoted keys and values, escape sequences (`\"`, `\\`, `\n`, `\t`), `//` comments, and unquoted tokens. Return a typed tree; reject malformed input with an error, never panic.
   - `steam.rs`:
     - from a Steam root, read `steamapps/libraryfolders.vdf` to get the library paths;
     - in each library, read `steamapps/appmanifest_*.acf` and extract `appid`, `name`, `StateFlags` (only fully installed = flag 4 set) and `LastPlayed` when present;
     - skip Proton/runtime entries (names starting with "Proton", "Steam Linux Runtime", "Steamworks Common Redistributables").
   - `flatpak.rs`: parse the text output of `flatpak list --app --columns=application,name,origin` (tab-separated) into items. Running the command is a side-effect trait (`AppLister`) with a Linux implementation and a fixture implementation for tests.
   - `catalog.rs`: merge Steam and Flatpak items. Sort by `last_played` descending, then title. Item ids are `steam:<appid>` and `flatpak:<appid>`.
   - `dbus.rs` + `main.rs` as in ruya-profiles. Steam roots default to `~/.local/share/Steam` and `~/.var/app/com.valvesoftware.Steam/.local/share/Steam` **of the active profile's user**. For now, take the home directory from env `RUYA_LIBRARY_HOME` (document that wiring it to the active profile is a follow-up).
3. Test fixtures under `services/ruya-library/tests/fixtures/` (a realistic `libraryfolders.vdf` with 2 libraries and 3 manifests, one of them Proton).

## Out of scope
- Launching anything (the session service, later).
- Non-Steam launchers (Heroic etc.).
- Image integration (systemd unit, D-Bus policy). Do it only if time remains, following `services/CLAUDE.md`, and mark it unverified.

## Acceptance criteria
- [ ] VDF parser: unit tests for nesting, escapes, comments, unquoted tokens, and 3 malformed inputs returning errors (`vdf::tests`).
- [ ] Steam: the fixture tree yields exactly the 2 real games (Proton skipped), with correct names, ids and `last_played` (`steam::tests`).
- [ ] Not-fully-installed manifests (StateFlags without bit 4) are excluded (test).
- [ ] Flatpak parsing handles empty output, normal rows and rows with missing columns, without panicking (`flatpak::tests`).
- [ ] The merged catalogue order is deterministic (test).
- [ ] `.\scripts\dev.ps1 rust` is green, including clippy for the Linux target.

## Verification
```powershell
.\scripts\dev.ps1 rust
```

## Docs to update
- `docs/specs/03-services-and-apps.md` §5 Library row: point to the crate and the contract.
- `docs/STATUS.md`: D-Bus serving is **unverified** (no bus on Windows).

## Hints
- Write the VDF parser by hand; it's small. Avoid adding a VDF crate unless it's pure Rust and maintained, and justify it in the commit if you do.
- `appmanifest` files sometimes contain keys in different case (`appid` vs `AppID`). Match case-insensitively.

## Outcome
Verified: host (unit tests and clippy for Windows and the Linux target; D-Bus serving, the `flatpak` command and a real Steam tree are **unverified**: no bus on Windows, no image change).

Built `api/dbus/org.ruyaos.Library1.xml` (`ListItems`, `Rescan`, `ItemsChanged`) and the crate `services/ruya-library`: `vdf.rs` (hand-written parser, depth-limited, errors never panics), `steam.rs` (library folders in new and old format, manifests with case-insensitive keys, bit 4 of `StateFlags`, Proton/runtime entries skipped), `flatpak.rs` (`parse_list`, `AppLister` with `FlatpakCli` on Linux and `FixtureLister`), `catalog.rs` (`Item`, `merge`, `scan`, `steam_roots`), `dbus.rs`, `main.rs` (`--session` lists demo Flatpak apps). 24 unit tests; fixtures in `tests/fixtures/` (2 libraries, 3 manifests, one Proton) use spaces, not Steam's tabs, because `lint-text` rejects tabs; the test writes them to a temp dir with the library paths filled in.

Decisions: ordering is last played, then case-insensitive title, then id. `launch` is `steam://rungameid/<appid>` for Steam and `flatpak:<id>` for Flatpak; `art` is `a{ss}` and always empty for now (artwork is for T-113). New dependency: `blocking` (runs the rescan off the executor; already in the tree through zbus), so `Cargo.lock` gains the crate entry only.

Left: the home directory comes from `RUYA_LIBRARY_HOME` (else `HOME`); wiring it to the active profile's user needs the session service (T-130). No unit, D-Bus policy or Containerfile entry (out of scope; an image task).
