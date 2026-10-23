# T-122 — CI on GitHub: read the first results, make it green, and run the same gates as `dev.ps1 test`

Status: in-progress (committed, awaiting push to verify) · Phase: 1 · Depends: — · Area: ci, scripts · Size: S

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
**State: committed locally, not pushed. The new `lint` job and the changed workflow have not run on GitHub yet; the "latest run is green" criterion needs the owner's go-ahead to push.**

**Runs seen** (public API, 2026-10-23; all workflow `ci`, event `push`, branch `main`):

| Run | Commit | `shell` | `services` | `image` |
|---|---|---|---|---|
| [39864834470](https://github.com/fatihyilmaz84/ruya-os/actions/runs/39864834470) | 22e8c4a (T-106) | success, 2 min | success, 1 min | success, about 23 min |
| [39864940064](https://github.com/fatihyilmaz84/ruya-os/actions/runs/39864940064) | 37e9711 (docs) | run `success`; per-job detail not read (the jobs endpoint answered 502 twice) | same | same |
| [39866431326](https://github.com/fatihyilmaz84/ruya-os/actions/runs/39866431326) | de6112e (docs) | success, 2 min | success, 1 min | success, 16 min (build, qcow2, smoke test, serial-log upload all green) |

Nothing was red, so there was nothing to fix. This also means the first Fedora/Linux build and offscreen test run of the shell passed (no API newer than Qt 6.8 in use), and the image job's `lint --fatal-warnings`, readiness marker and disk size from the Windows drill hold on GitHub's runners with KVM.

**Built:**
- `scripts/lint-tokens.ps1`: the token lint extracted from `dev.ps1`, same patterns and `// token-ok:` opt-out. It prints `file:line` for each finding and exits 1. It builds paths with nested `Join-Path` and trims either separator, so it also runs under `pwsh` on Linux. `dev.ps1`'s `Test-Tokens` now calls it and records the exit code.
- `.github/workflows/ci.yml`: new `lint` job (Ubuntu runner, `pwsh scripts/lint-tokens.ps1`, outside the Fedora container); `permissions: contents: read`; a `concurrency` group that cancels superseded runs on the same ref; `workflow_dispatch`; `timeout-minutes` on every job; `image` now also waits for `lint`. Actions stay pinned to `@v4`; no secrets.
- Docs: `docs/dev-setup.md` ("Local checks and CI": job-to-command table and how to read a failed run), `image/CLAUDE.md`, `shell/CLAUDE.md`, and the CI paragraph in `docs/specs/01-platform.md`.

**Decision on the `image` job:** it stays on every push and pull request. It took 16–23 minutes in the runs above, it is free on a public repository, superseded runs are cancelled, and it is the only check that the image still boots with `RUYA_BOOT_OK`. If it turns into a bottleneck, the fallback is `main` plus `workflow_dispatch`; that is a one-line `if:` change.

**Verification:**
- Probe: a scratch `shell/qml/LintProbe.qml` containing `Behavior on x { NumberAnimation { duration: 120 } }` made `scripts/lint-tokens.ps1` print `shell\qml\LintProbe.qml:3: Behavior on x { NumberAnimation { duration: 120 } }` and `Move these into Theme.qml tokens, or add '// token-ok: <reason>'.`, exit 1. The file was removed and the next run exited 0.
- `.\scripts\dev.ps1 test` → ALL GREEN (88 passed, 8 skipped screenshot tests); the token lint step prints `ok: token lint` as before.
- **Unverified:** the workflow YAML on GitHub, and `lint-tokens.ps1` under Linux `pwsh` (no `pwsh` on this machine; the runner image has it). If the `lint` job fails on its first run, suspect path handling in that script.

**Deviations:** the second run's per-job results were not read (API 502); its run-level conclusion was `success`, which requires every job to have succeeded. No UI change, so no screenshots.

**Follow-up:** after the owner pushes, read the new run; when `lint`, `services`, `shell` and `image` are all green, set T-122 to `done` and add the run link here.
