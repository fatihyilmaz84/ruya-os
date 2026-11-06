# T-234 — `org.ruyaos.Play1` contract, mock and shell client

Status: todo · Phase: 7 · Depends: T-230, T-231 · Area: api, shell · Size: M · Owner: builder

## Goal
The shell can ask the (future) `ruya-play` service to inspect a package on a drive, install it, verify it and report progress, with a mock that follows the contract so the UI (T-236) can be built and tested on Windows before the service exists.

## Read first
- `docs/specs/05-play-packages.md` §7.3 (pipeline), §8, §9.2, §11
- `api/dbus/org.ruyaos.Store1.xml` and `shell/src/store` (job model, `JobBook`, backend/mock/D-Bus client split), `shell/PATTERNS.md`, `CLAUDE.md` rule: contract first, mock and client follow
- The service that will implement it: T-238 (name it in the XML comments so the mock cannot drift unnoticed)

## Scope
1. **Write the XML first:** `api/dbus/org.ruyaos.Play1.xml`. Suggested methods (extend as needed, contracts are drafts): `ListSources()` (mounted drives with candidate packages, data only), `Inspect(path)` -> a dictionary (id, names, version, build, developer, genres, players, controller, age label, size, requirement result, `permissions` list with risk, tier, signer key id and name, key state `new | same | different`, vetted art paths, problems list), `Install(path, options)` -> `(status, job)`, `Verify(app_id)`, `Cancel(job)`, `ListJobs()`; signals `JobProgress`, `JobFinished` (statuses: `ok`, `invalid`, `bad-signature`, `different-developer`, `needs-developer-mode`, `needs-admin`, `revoked`, `no-space`, `unsupported`, `failed`), `SourcesChanged`. Update/feed methods arrive with T-241.
2. `shell/src/play/` following the Store pattern: `Play` singleton, `PlayBackend` interface, mock backend, D-Bus client; the mock serves fixture packages (a Wine game with a full permission set, a native game, an unverified one, a revoked one, a corrupted one, a high-risk one) and enforces the same statuses and ordering rules as the contract.
3. The shell registers the types in `shell/CMakeLists.txt`; `RUYA_SERVICES=mock` and the Linux default follow the Store.

## Out of scope
- The Rust service (T-238), any UI (T-236), updates (T-241).

## Acceptance criteria
- [ ] The XML lints as the other contracts; a test checks that the mock implements every method and signal in the XML (copy the existing contract/mock drift test if one exists, else add one).
- [ ] Shell tests: inspect shows each fixture's fields; install runs to `ok` with monotonic progress; each failure status reaches `jobFinished`; a job survives the page closing; service loss clears jobs the way the Store does (`tst_play.qml`).
- [ ] `dev.ps1 test` ALL GREEN, qmllint clean.
- [ ] VM (lead run): none yet; the D-Bus client is exercised when T-238 lands (`vm-play-check.sh`). Outcome says `host (vm pending)`.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- Spec 05 §7.3 with the final method list; spec 03 §4 gets one line linking to 05.

## Hints
- Statuses are strings in the XML; keep them one list used by the service, mock and shell translations.

## Outcome
_Filled in by the implementer._
