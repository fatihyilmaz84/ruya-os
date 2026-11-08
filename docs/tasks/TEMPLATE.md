# T-nnn — <title>

Status: todo · Phase: n · Depends: T-xxx, … · Area: shell | services | api | image | docs · Size: S | M · Owner: builder | lead · Developer surface: none | internal | public-API | public-format

## Goal
<One or two sentences: the user-visible result.>

## Read first
- `docs/specs/…` §…
- UI task: `docs/specs/04-design-system.md` §… (tokens/components used; new ones allowed: none | …)
- `<existing files to read>`

## Scope
1. …
2. …

## Out of scope
- …

## Acceptance criteria
- [ ] … (test: `tst_xxx.qml::test_yyy`)
- [ ] … (screenshot: `output/shell-shots/n-name.png` shows …)
- [ ] UI tasks - UX: from every new state Back leaves; focus lands sensibly after open/close/error; readable at 10 ft; Outcome has a `UX notes:` line
- [ ] public-API / public-format tasks only (`docs/developers/api-surface.md`): XML with `org.ruyaos.Stability` tag; a paragraph in `docs/developers/`; a minimal sample (`lint-dev-docs.ps1` compiles or runs it against the mock); mock support so a developer can test off the console; a conformance test incl. abuse cases (test: `...`)
- [ ] VM (this task | lead run): `scripts/vm-…-check.sh` … (service-facing tasks only, PLANNING.md Lessons)

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- …

## Hints
- …

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
