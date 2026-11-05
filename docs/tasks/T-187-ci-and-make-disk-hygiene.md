# T-187 — CI runs the font check; `make-disk.sh` doesn't silently build a disk you can't log into

Status: done · Phase: 0 · Depends: — · Area: ci, scripts · Size: S · Owner: builder

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
Verified: host (Git Bash on Windows for the script checks; `dev.ps1 test` on the host; the CI workflow itself has not run on GitHub).

Built:
- `.github/workflows/ci.yml`: the `lint` job got `actions/setup-python@v5` (3.12) and a "Font coverage" step running `python -I scripts/check-font-coverage.py .`, next to the icon lint. The `image` job's "Build qcow2" step sets `RUYA_NO_DEV_KEY: "1"` (`image/bib/config.toml` is git-ignored, so it never exists on the runner; this is the only make-disk call in CI, `smoke-test.sh` does not call it).
- `scripts/make-disk.sh`: the config choice is now `choose_config`. `image/bib/config.toml` present: used. Absent and `RUYA_NO_DEV_KEY=1`: `image/bib/disk.toml`, and it says "keyless disk". Absent otherwise: prints what is wrong and two fixes (copy the example, or the file from the main checkout) to stderr and exits 1, before `mkdir output`, podman or sudo. `make-disk.sh --check-config` runs only this check and builds nothing.
- `docs/dev-setup.md`: a sentence under "Dev VM access" about fresh worktrees, and the CI table (lint row lists the icon, test and font steps; image row shows the variable).

Checks run (Git Bash, worktree has no `config.toml`): `bash -n` OK; `--check-config` without the file: message, exit 1; `qcow2` without the file: same message, exit 1, no `output/` created; `RUYA_NO_DEV_KEY=1 --check-config`: "config: image/bib/disk.toml (RUYA_NO_DEV_KEY=1: keyless disk ...)", exit 0; with a temporary copy of the example as `config.toml`: "config: image/bib/config.toml (dev SSH key)", exit 0 (file removed afterwards). Workflow YAML parsed with PyYAML (steps and the env block as intended); `actionlint` is not installed here. No image was built.

Deviations: none. The font check also exists in `dev.ps1 shell` (not `test`'s text/board group), so the docs table names it there.
