# T-122 — CI on GitHub: read the first results, make it green, and run the same gates as `dev.ps1 test`

Status: todo · Phase: 1 · Depends: — · Area: ci, scripts · Size: S

## Goal
The `ci` workflow on GitHub runs the same checks as the local gate, passes, and stays understandable. The repository is public, so a red or stale workflow is visible to everyone.

## Read first
- `.github/workflows/ci.yml` and `scripts/dev.ps1` (what the local gate runs: Rust fmt/clippy/tests, shell build, token lint, qmllint, Qt Quick tests)
- `scripts/smoke-test.sh`, `scripts/build.sh`, `scripts/make-disk.sh` (what the `image` job runs) and `docs/dev-setup.md` (how the local boot test differs)
- The first runs of the workflow on `main`: https://github.com/fatihyilmaz84/ruya-os/actions (also readable through the public API `https://api.github.com/repos/fatihyilmaz84/ruya-os/actions/runs`)
- STATUS session logs 2026-10-23 (T-116, T-106, T-117): what changed in the gate since the workflow was written

## Scope
1. **Read the results** of every run so far (all three jobs, and the logs of any failure) and record them in the Outcome. At planning time (2026-10-23) the `services` and `shell` jobs had passed on the first push, which is the first Linux build and offscreen test run of the shell on Fedora's Qt; the `image` job (a full bootc build, a qcow2 and `scripts/smoke-test.sh` under KVM) was still running, so its result is unknown.
2. **Fix whatever is red.** For the `image` job, the likely issues are the ones the Windows drill already found (the readiness marker, test disk size, `bootc container lint --fatal-warnings`, a bib config without the dev SSH key). Decide with the logs, not by guessing, and note whether the job is worth running on every push (it takes tens of minutes): the options are every push, or only `main` plus manual `workflow_dispatch`. Pick one and say why. Keep the serial log artifact.
3. **Bring the gate up to date.** Add the token lint (T-117) to CI. It lives in `dev.ps1` today; extract it to `scripts/lint-tokens.ps1` called by both `dev.ps1` and the workflow (the Ubuntu runner has `pwsh`; the shell job runs in a Fedora container, so give the lint its own small step or job outside the container). Behaviour must not change: it still fails on a literal non-zero `duration:`, a quoted hex colour or `Qt.rgba(` outside `Theme.qml`, and `// token-ok:` still opts out.
4. Add `permissions: contents: read`, a `concurrency` group that cancels superseded runs on the same ref, and pin the third-party actions to a major version (already the case; keep it).
5. Document in `docs/dev-setup.md` how local checks map to CI jobs, and how to read a failed run.

## Out of scope
- Releases, signing, publishing images (a registry, secrets). Nothing in the workflow may need a secret.
- Windows CI (the MSVC build stays a local check).
- Matrix builds over Qt versions.

## Acceptance criteria
- [ ] The Outcome lists each workflow run seen (id, commit, per-job result), and what was done about each failure.
- [ ] The latest run on `main` after this task is green for every job, or the Outcome states which job is intentionally manual and why (link the run).
- [ ] The token lint runs in CI. Show that `scripts/lint-tokens.ps1` fails locally on a file containing `duration: 120` (paste the output, then remove the line). A failing CI run on a throwaway branch is optional and needs the owner's go-ahead to push.
- [ ] `dev.ps1 test` is ALL GREEN, and still ends with the same lint step output (the extraction changed no behaviour).
- [ ] The workflow needs no secrets and sets least-privilege `permissions`.

## Verification
```powershell
.\scripts\dev.ps1 test
```
plus the Actions page for the pushed commit (pushing is the owner's call: ask in the Outcome if the push has not happened yet).

## Docs to update
- `docs/dev-setup.md` (CI mapping), `image/CLAUDE.md` (the CI sentence), `docs/STATUS.md` (the CI Inbox note is gone).

## Hints
- Do not push from a builder session unless the owner asked for it (root `CLAUDE.md`). If the fix needs a push to be verified, finish the task as `in-progress` with the commit ready, and say so.
- The shell job installs Fedora's Qt (6.8+ range), not 6.10.3: CI is also the check that no API newer than 6.8 sneaked in.
- Reading runs needs no login: `WebFetch` works on the public API; `gh` is not installed on this machine.

## Outcome
_Filled in by the implementer: what was built, files, how it was verified, deviations, follow-ups._
