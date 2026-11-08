# T-351 - API level: RUYA_API_LEVEL, the AppStream minimum, the Store filter, an XML-diff changelog

Status: todo · Phase: 7 · Depends: — · Area: image, services, scripts, docs · Size: S · Owner: builder · Developer surface: public-format

## Goal
An app can say "I need API level N", the console knows its level, the Store hides apps it cannot serve, and the release notes list which public elements changed (ADR-022, `docs/developers/api-surface.md` "Versioning"). Everything stays experimental until the first release: this builds the mechanism, not a promise.

## Read first
- `docs/developers/api-surface.md` (Versioning), `docs/developers/appstream-metadata.md` (how `x-ruya-*` keys are documented and read)
- `ruya-store` (`services/ruya-store`: how it reads AppStream keys, e.g. the age rating of T-211/T-342), `image/` (where `os-release` is written: `image/CLAUDE.md`), `api/dbus/org.ruyaos.Store1.xml`
- `scripts/lint-dev-docs.ps1` (T-350 reads the same XML annotations)

## Scope
1. **Level.** `RUYA_API_LEVEL=<integer>` in `/usr/lib/os-release` (set where the image writes its version; starts at `0`, "experimental, no promise"). A tiny shared reader in Rust (`ruya-store` and later `ruya-platform` use it) and in the shell's mock (a constant).
2. **Metadata.** The AppStream key `x-ruya-min-api-level` (integer, default 0). Document it in `appstream-metadata.md` (with the existing keys table) and read it in `ruya-store`; Store1 exposes a per-app `compatible` flag (extend the contract in the same commit, with the mock and the D-Bus client).
3. **Store.** The shell hides an app whose minimum is above the console's level from lists, and its direct page says "Needs a newer RuyaOS" with Install disabled. An installed app that no longer fits keeps running and is flagged in its page (never removed).
4. **Changelog.** `scripts/api-changelog.ps1 <old-ref> <new-ref>` diffs the elements tagged `org.ruyaos.Stability` between two git refs of `api/dbus/*.xml` and prints added, changed (arguments, `Since`) and deprecated elements per level, as Markdown. No public element exists yet: a fixture XML in `scripts/` tests it in `dev.ps1`'s self-check.

## Out of scope
- Any promise of stability; enforcing deprecation windows (a later release task); the Platform1 service (T-352).

## Acceptance criteria
- [ ] Rust tests: the key parses (missing, 0, N, garbage -> 0) and `compatible` follows the level (test in `ruya-store`).
- [ ] QML tests (mock): an app with a high minimum is absent from lists and its page disables Install with the text; focus and Back as on any app page.
- [ ] `api-changelog.ps1` fixture test: added, changed and deprecated elements are listed; no change prints "no public API changes".
- [ ] VM (lead run): `scripts/vm-store-check.sh` extended: `os-release` has `RUYA_API_LEVEL`; a test app with a minimum of 99 reports `compatible=false`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `appstream-metadata.md`, `api-surface.md` (remove "planned" for the key), `03` §4.3, `01-platform.md` (os-release), the XML and `dev-setup.md` if needed.

## Hints
- Developer surface is `public-format` because the AppStream key is a format developers write.
- Follow how T-342 (age rating) passes a per-app field through Store1 and the page.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
