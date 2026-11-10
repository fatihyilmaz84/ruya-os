# T-241 — Updates: signed feeds, same-key rule, rollback

Status: todo · Phase: 7 · Depends: T-231, T-238, T-240 · Area: services, shell · Size: M · Owner: lead

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Also owns what T-231 left open: fetching the revocation list and what happens to an installed package that is revoked later (refuse to launch, say why), with tests. Downloads are ADR-026 jobs in the one job record (T-388), not a private fetcher.

## Goal
An installed `.play` can be updated safely: from a remote through the Store, from its developer's signed feed (opt-in), or by installing a newer package by hand. All three obey the same rules: same signing key (or rotation), `build` only increases, permissions that grow need confirmation, data is kept, and the player can roll back.

## Read first
- `docs/specs/05-play-packages.md` §11 (all), §9.2, §8 (diff); T-231 (continuity, rotation), T-240 (diff), T-238 (install pipeline)
- `api/dbus/org.ruyaos.Store1.xml` (`Update`, `Rollback`, `ListJobs`), `services/ruya-update` (schedule, idle rules, retry), T-221 (app options menu), T-159 (restart/announce wording patterns)

## Scope
1. **Feed format and verifier** (pure): `feed.json` + `feed.json.sig` by the installed key or a rotation; rules from 05 §11.2 (host pinned, redirects within the registrable domain, `expires`, `build` greater, `min_os`, size cap); tests with a fake clock.
2. **Fetcher** in `ruya-play`: only the service downloads (never the game, never the shell); https only with the OS trust store; size and time caps; writes into `incoming/`; then the normal install pipeline with the update-specific checks (same key, permission diff). Runs when the console is idle and online, weekly and on opening the app's page, per-app toggle, **default off** and asked at install (`Play1` gets `SetUpdateCheck(app, bool)`; the confirm sheet in T-236 gets the question: extend that screen here).
3. **Store-installed packages** update through `Store1` as any app; the manifest `update` block is ignored for them (test).
4. **Rollback:** keep the previous deployment until the next successful launch; "Roll back to <version>" via `Store1.Rollback`; a downgrade that is not a rollback of an installed deployment is refused.
5. Shell: "Update available" on the app page and in Options, the "update adds ..." words and admin gate (reuse T-156 flow), progress, failure sentences; "Different developer" error when keys differ.
6. Data and prefix: `epoch` handling is T-239's; here only check that an update keeps `data/` and `config/` untouched.

## Out of scope
- Delta downloads, automatic update of non-official tiers, a push channel, pre-release channels beyond the `channel` string.

## Acceptance criteria
- [ ] Feed tests: valid; expired; replayed older feed; wrong key; rotation; host changed by redirect to another domain; `build` equal or lower; `min_os` too high; oversize; non-https (`tests/feed.rs`, each its own named case).
- [ ] Update pipeline tests with the importer fakes: update with the same key succeeds and keeps data; different key refused; added `network` shows the diff and does not proceed without confirmation; added `devel` needs admin; interrupted download leaves the old version running and installed.
- [ ] Privacy: with the toggle off no network request is made (test with a counting fake transport); Store-installed packages never contact the feed host.
- [ ] Shell tests for the update states and the confirm questions; screenshots English/Turkish.
- [ ] VM (lead run): `vm-play-check.sh update`: a local HTTPS test server (self-signed CA added in the test image only) serves a feed; update succeeds, rollback restores the previous version and the save file written before the update is intact; a tampered second release is refused.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- Spec 05 §11 as built; the publishing chapter content goes to T-243.

## Outcome
_Filled in by the implementer._
