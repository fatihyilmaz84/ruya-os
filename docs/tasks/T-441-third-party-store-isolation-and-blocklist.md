# T-441 - A third-party store cannot replace anything: priority, reserved names, runtimes, catalogue caps, the blocklist

Status: todo · Phase: 3 · Depends: T-440 · Area: services, api, image (one data file), scripts · Size: M · Owner: builder · Complexity: hard · Developer surface: internal

## Goal
The rules of `docs/specs/10-stores.md` §3 and §6 hold against a store that is trying to break them: it cannot shadow or update an app or runtime of a trusted store, cannot use reserved names, cannot flood or poison the catalogue, and a blocklisted store is refused and switched off. This is the security half of ADR-032; no third-party store ships in an image before it.

## Read first
- `docs/specs/10-stores.md` §3, §5 (blocklist row), §6, §7; ADR-032
- T-440's Outcome (how kept apps and removed remotes behave in Flatpak)
- `services/ruya-store/src/` (`appstream.rs`, `flatpak.rs`, `service.rs`), `services/CLAUDE.md`, `image/CLAUDE.md` (adding a data file)
- Flatpak documentation for remote priority (`--prio`), per-remote filters (`--filter`), and how a ref's origin is pinned

## Scope
1. **First step, written into the Outcome before the code:** which Flatpak mechanism enforces each rule of §3 (1 to 4), tried against a real hostile repository in a VM or the WSL distribution; where Flatpak alone does not enforce one, the service does (it refuses the job) and the test says so.
2. **Replacement and names:** third-party remotes get a lower priority than both built-in stores and a filter that denies runtimes and the reserved prefixes; the catalogue drops, per third-party store, every id a trusted store offers and every reserved id (logged with the store id). `Update` of an installed app only ever uses its origin store.
3. **`(store, id)`:** `Install` and `GetApp` take the store; an empty store means the best trusted one that offers the id, never a third-party one when a trusted one has it. The same id in two third-party stores is two catalogue entries. XML, mock and client follow.
4. **Runtimes:** a third-party app's runtime is resolved from trusted stores only; otherwise the job ends `missing-runtime` and nothing is installed.
5. **Catalogue caps (§3.6):** per store 20 MB unpacked AppStream and 5 000 apps (state `partly-shown`), text length caps, picture URLs only `https` to non-private hosts (the service drops others; the record's `icon`/`tile`/`hero` are then empty).
6. **Blocklist:** `image/files/usr/share/ruyaos/store-blocklist` (empty, with a comment describing the format) in the image; read at start; `PreviewStore`/`AddStore` answer `blocked`; an added store that is on a newer list is turned off with state `blocked` at start. A malformed line is skipped and logged, never fatal.
7. A hostile fixture store for the tests: a builder script (`scripts/make-hostile-store.sh`) that produces a signed repository offering a shadow of a Flathub app id with a higher version, an `org.ruyaos.` id, a runtime named like the freedesktop one, 6 000 apps' worth of AppStream, a 30 MB description, a picture URL on `http://192.168.0.1/`.

## Out of scope
- Screens (T-442, T-443). Scheduled updates. Who decides blocklist entries (owner, ADR-032).
- Permission ceilings for every store (T-426 item 7).

## Acceptance criteria
- [ ] Rust tests with the fake Flatpak and AppStream fixtures, one per rule of §3 (1 to 4, 6, 7) and per blocklist case, named in the Outcome; each has a revert check.
- [ ] `tst_store_stores.qml` (mock): the same id from two third-party stores shows twice with different `store`; an id a trusted store has never shows a third-party copy.
- [ ] VM (lead run): `scripts/vm-store-check.sh hostile`: with the fixture store added, the shadowed Flathub app still installs from Flathub and is not updated from the fixture; the reserved id and the runtime are absent from `Search` and refused by `Install`; the catalogue is `partly-shown` and the service's memory stays under a stated bound; a blocklist file with the fixture's fingerprint (written to a test path the unit reads through `RUYA_STORE_BLOCKLIST`, drop-in as in T-440) turns the store off at restart. No step SKIPs.
- [ ] The image contains the empty blocklist (`check-image-manifest.sh` or the existing manifest check lists it).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/10-stores.md` §3/§6 (built marks; the mechanism per rule in one line each), `03` §4.3, `docs/dev-setup.md`.

## Hints
- The data file is the only image change; if a unit, capability or policy has to change, tell the lead (then it is "VM (this task)").
- If a rule cannot be enforced at all with the Flatpak in the image, do not weaken the rule: return `partial` with what was tried.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: vm-store-check.sh hostile)`._
