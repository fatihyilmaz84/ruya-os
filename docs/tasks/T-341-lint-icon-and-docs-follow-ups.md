# T-341 - Lint and docs follow-ups: sample metainfo check, icon spike contour, member-lint note, `vm-goto.ps1`

Status: todo · Phase: 2 · Depends: — · Area: scripts, docs · Size: S · Owner: builder

## Goal
Four small review findings that each weaken a check or a guide silently. Close them together.

## Read first
- The Inbox lines tagged T-297, T-300 and T-324 in `docs/STATUS-parked.md`, "Inbox triage 2026-11-08 (lead-5)" (verbatim)
- `scripts/lint-dev-docs.ps1`, `scripts/subset-icons.sh` and the shipped icon cut (T-297 Outcome), `scripts/lint-qml-members.ps1` and `scripts/lint-test-members.ps1` (the member lints named in `shell/PATTERNS.md`), `scripts/vm-goto.ps1`, `docs/specs/04-design-system.md` §7 (accessibility)

## Scope
1. `lint-dev-docs.ps1`: fail when a fenced xml block whose root is `<component>` has no sample metainfo path in the 3 lines before it (today the comparison with the sample is skipped without a word).
2. The shipped filled icon cut has a zero-area spike contour in glyph 2: find out whether `remove-overlaps` (or a cleanup) in `subset-icons.sh` removes it, fix it, and add a check to the script's output that counts zero-area contours (0 expected). The script needs WSL: if it cannot run here, mark the fix **unverified** and list `subset-icons.sh` in the VM queue line of the Outcome.
3. `shell/PATTERNS.md`: a note that a `const` declared inside a block-bodied arrow function blinds the QML member lint for the whole test file (T-300 review), with the workaround; and the lint should warn instead of going blind if that is simple.
4. `docs/specs/04-design-system.md` §7: the sentence "Settings -> Profiles add and manage flows (T-186)" is stale since T-324 (My profile / Manage profiles): fix the names. **Done in 6ffcd85** (split out as ticket RUY-177 in Paper Plane, the pilot, 2026-11-12); the other four items remain.
5. `scripts/vm-goto.ps1`: its targets changed with T-324 (Settings My profile / Manage profiles) and were not run: check each target against the shell, fix, and say which were run.

## Out of scope
- The Settings info-row component (T-343), new lints.

## Acceptance criteria
- [ ] A self-check of the lint in `dev.ps1 docs` next to the existing "developer guide lint self-check (...: rejected)" cases (copy how they build a temporary folder): `dev_docs_lint_fails_on_a_component_block_without_a_sample_path` (revert: skip the check, the bad doc passes, test red).
- [ ] The icon script prints `zero-area contours: 0` for the shipped cut, or the Outcome says why it could not run (unverified).
- [ ] `vm-goto.ps1` targets listed in the Outcome with run/not run.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN (includes the docs lints).

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `shell/PATTERNS.md`, `docs/specs/04-design-system.md` §7, `docs/dev-setup.md` (icon script output).

## Hints
- Backslashes in PowerShell/regex: write with Write/Edit, then `scripts/lint-text.ps1`.

## Outcome
_Filled in by the implementer._
