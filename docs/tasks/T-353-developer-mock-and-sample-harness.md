# T-353 - Developer harness: a Platform mock, a sample app and a conformance runner that run in CI

Status: blocked · Phase: 7 · Depends: T-352, T-350 · Area: samples, scripts, ci, docs · Size: M · Owner: builder · Developer surface: public-API

**Blocked on** T-352 (which is blocked on ADR-022). Planned now so the Definition of done of a public API has somewhere to land.

## Goal
A developer without a console can build a sample, call every documented Platform API against a mock, and run the same conformance checks the console passes (ADR-022, `docs/developers/api-surface.md`). The harness exists once; each capability task only adds its interface to it.

## Read first
- `docs/developers/api-surface.md`, `docs/developers/testing-and-debugging.md`, `samples/hello-game/` (Makefile, `tests/`), `scripts/lint-dev-docs.ps1` (T-350 `-Samples`)
- `api/dbus/org.ruyaos.Platform1.xml` (T-352); the shell's mock pattern in `shell/src/network`

## Scope
1. **Mock server** `tools/platform-mock/` (Python 3 standard library or Rust; CC0/MIT): serves `org.ruyaos.Platform1` on a **session bus** from the XML in `api/dbus/` (so it never drifts: the methods are read from the tagged elements and answer from a small scenario file), with commands to fire signals (`suspend`, `resume`, `stopping`), to turn a permission off and to simulate a flood.
2. **Sample** `samples/platform-demo/` (CC0, C, no SDL): connects, calls the lifecycle interface, prints; `make test` runs it against the mock. Its relevant lines are quoted in the chapter with the `/* sample: ... */` markers that T-297 checks.
3. **Conformance runner** `scripts/conformance.ps1` and `.sh`: for every tagged element, call it on the target (the mock, or a real console over SSH given a host) with a valid call and the abuse cases from `api-surface.md`, and compare the status strings with the XML documentation; prints `CONFORMANCE: n/n`. The VM check of each capability runs it on the real service.
4. **CI:** the mock plus `samples/platform-demo` `make test` in the docs/samples job; `dev.ps1 docs` runs the mock part when Python is found.
5. **Docs:** `testing-and-debugging.md` gains "Testing the Platform API off the console".

## Out of scope
- Capabilities other than Lifecycle (each adds its own scenario and sample lines); packaging the mock as a Flatpak.

## Acceptance criteria
- [ ] `make -C samples/platform-demo test` passes against the mock in CI; with the mock stopped it fails with a readable message (test).
- [ ] The mock rejects an element that is not in the XML (test) and picks up a new tagged element without code changes (test with a fixture XML).
- [ ] The conformance runner passes on the mock and fails on a mock made to answer a wrong status (test).
- [ ] `lint-dev-docs.ps1 -Samples` passes; `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `testing-and-debugging.md`, `api-surface.md`, `dev-setup.md`, `fullscreen-and-lifecycle.md` (sample lines).

## Hints
- Missing today for every other public capability: its interface in the mock, its sample lines and its chapter paragraph; that work belongs to the capability's own task, not to this one.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
