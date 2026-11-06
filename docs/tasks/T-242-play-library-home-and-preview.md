# T-242 — Library, Home hero, preview loop and save paths for `.play` apps

Status: todo · Phase: 7 · Depends: T-232, T-238 · Area: services, shell, api · Size: M · Owner: builder

## Goal
An installed package looks like a first-class game: its icon, logo and hero art in Games and on Home, the muted preview loop on the hero after a moment of focus, the detail page with screenshots, trailer and links (text and QR), and its declared save paths known to the backup task.

## Read first
- `docs/specs/05-play-packages.md` §5, §10, §12; `docs/specs/03-services-and-apps.md` §5 (Library row), `api/dbus/org.ruyaos.Library1.xml`, `services/ruya-library`
- `docs/specs/04-design-system.md` §5 (Art card, Hero block, App art), T-235 components; T-215 (`x-ruya-save-paths`), T-163 (how `ruya-library` reads exports)

## Scope
1. Extend `Library1` (XML first; extend the mock and D-Bus client): per item art paths (icon, logo, hero, card, cover), genres, players, controller, age label, `play` flag with trust tier. `ruya-library` reads them from the vetted art and `play.json` copy in the app's exports (no raw package access; it keeps `ProtectHome=yes`).
2. Shell: `AppArt` uses the card/hero art, `HeroBlock` uses the logo instead of the text title when present, genre tint from the first genre; `preview` loop plays muted on the Home hero one second after focus, stops on blur, never under reduced motion, never on the Performance tier (05 §12).
3. Detail page sections that exist after install: screenshots, trailer (the vetted file through the shell media stack), links as text plus QR (generated locally; check for an existing QR helper before adding a dependency, licence recorded), "What's new" (version notes from the manifest `changelog` if added, else hidden), source/trust badge, signer.
4. Save paths: the importer writes `data.saves/cache` into the app's exported metadata in the `x-ruya-save-paths`/`x-ruya-cache-paths` form T-215 expects; a test shows T-215's reader (or its fixture) understanding them, with the `prefix:` root resolved.
5. Turkish strings.

## Out of scope
- Video hardening (Q5), the Store catalogue listing of remote `.play` apps, cloud saves.

## Acceptance criteria
- [ ] `ruya-library` tests: a fixture installation with a `play.*` app lists art and fields; a package without art falls back to the tile; a missing/garbled copy of `play.json` yields a plain item, not an error (`tests/play_items.rs`).
- [ ] Shell tests: Home hero shows the logo and tint; preview starts after the delay and stops on blur, off under reduced motion and on Performance; detail sections appear only when data exists (`tst_playlibrary.qml`, properties not pixels).
- [ ] Screenshots (Wine fixture with full art, fixture with only an icon) English/Turkish reviewed against `04` §8.
- [ ] VM (lead run): `vm-library-check.sh` extended: the installed fixture appears with art paths readable by `ruya-shell`.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- Spec 05 §12, spec 03 §5 (Library), `api/dbus/org.ruyaos.Library1.xml` comments.

## Outcome
_Filled in by the implementer._
