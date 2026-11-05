# T-187 — CI runs the font check; `make-disk.sh` doesn't silently build a disk you can't log into

Status: todo · Phase: 0 · Depends: — · Area: ci, scripts · Size: S · Owner: builder

## Goal
Two small guards. CI runs `scripts/check-font-coverage.py` (T-145) next to the icon lint, so a dropped glyph fails on GitHub too. And `scripts/make-disk.sh` stops quietly falling back to `disk.toml` (no SSH key) when `image/bib/config.toml` is missing, which happens in every fresh worktree.

## Read first
- `.github/workflows/ci.yml` (the `lint-icons.ps1` step, line ~30) and `scripts/dev.ps1` lines ~280-300 (how `test` runs the font check)
- `scripts/make-disk.sh` lines ~10-20; `image/bib/config.toml.example`; `docs/dev-setup.md` (Dev VM access, "Disk space")

## Scope
1. CI: add a step running `python -I scripts/check-font-coverage.py .` (standard-library only; use the Python the job already has or `actions/setup-python` at a pinned major) in the job that runs the other lints.
2. `make-disk.sh`: if `image/bib/config.toml` is absent, print what is wrong and how to fix it (copy the example, or the file from the main checkout) and exit non-zero, unless `RUYA_NO_DEV_KEY=1` is set (an intentional keyless disk, e.g. CI's image job: check what it does and set the variable there if it needs it). `smoke-test.ps1` for CI must keep working.
3. `dev-setup.md`: one line under "Dev VM access" about worktrees needing the file.

## Out of scope
- Anything in the Containerfile, the installer, or other lints.

## Acceptance criteria
- [ ] `bash -n scripts/make-disk.sh`; running its config check without the file (a dry check that doesn't build) exits non-zero with the message; with `RUYA_NO_DEV_KEY=1` it proceeds to the keyless path (shown by the script's own output, no image build needed: factor the check into a function you can call, or add `--check-config`).
- [ ] CI yaml is valid (`actionlint` if present, else read twice) and contains the font step; `.github/workflows/ci.yml` still has the image job's make-disk call working without a key (variable set).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```
and the `bash -n` / config check above in WSL or Git Bash.

## Docs to update
- `docs/dev-setup.md`; the CI mapping table there ("Local checks and CI") gets the font check if it lists lints.

## Hints
- Shell scripts stay LF with the exec bit; no Windows-mangled backslashes.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
