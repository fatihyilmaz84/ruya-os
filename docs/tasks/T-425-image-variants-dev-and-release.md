# T-425 - Two image variants: `dev` (SSH, dev key, debug) and `release` (none of them), with a check

Status: todo · Phase: 2 · Depends: T-424 · Area: image, scripts, docs · Size: M · Owner: lead · Complexity: complex · Developer surface: none

## Goal
`01-platform.md` §3.7 says debug features exist only in `dev` channel images, but there is one image and it enables `sshd` and carries the development key path. After this task `scripts/build.sh` builds either variant, the release variant has no remote shell, no development key, no debug door, and a check proves it. Nothing is published by this task.

## Read first
- `docs/specs/01-platform.md` §3 (all), §3.7; `image/CLAUDE.md`; `image/Containerfile`, `image/build/enabled-units.txt`, `image/build/98-guard.sh`, `scripts/build.sh`, `scripts/check-image-manifest.sh`
- `docs/dev-setup.md` (the lead's SSH workflow, the Dell), `image/bib/config.toml` handling (git-ignored key)
- T-424's baseline (`image/security-baseline.json`)

## Scope
1. A build argument `RUYA_VARIANT=dev|release` (default `dev`, so every existing script and the Dell workflow keep working). The variant is written into the image (`/usr/lib/ruyaos/variant`) and shown in About.
2. `release`: `sshd` not enabled and not socket-activatable, no authorised key, root and service accounts locked, no debug or inspector units (T-418 will add its socket to the dev list only), no passwordless sudo, the serial console login off.
3. Base images in the Containerfile are pinned by digest, with a script or documented recipe that updates the digests (`docs/dev-setup.md`).
4. `image/security-baseline.json` gets a section per variant; `vm-security-check.sh` reads the variant from the image and uses its section: on `release` the port list has no SSH, the account list no login.
5. `check-image-manifest.sh` and `98-guard.sh` refuse a `release` build that contains a development-only package or unit (one list, in one file).
6. How a `release` image is tested without SSH: the checks that need a shell run on `dev`; `release` is checked from outside (boot marker on the serial log, ports probed from the host) and by mounting the disk image. Write the recipe; do not weaken any existing check.

## Out of scope
- Signing, update channels, full-disk encryption, factory reset (T-426).
- The installer ISO that erases every disk: only record what the release installer must ask (an Inbox line or T-426).
- Publishing an image anywhere.

## Acceptance criteria
- [ ] VM (this task): `RUYA_VARIANT=dev` builds, boots, `smoke-test.ps1` gives `RUYA_BOOT_OK`, the existing VM queue passes unchanged.
- [ ] VM (this task): `RUYA_VARIANT=release` builds and boots to the shell (boot marker without SSH, per scope 6); from the host no TCP port answers; the mounted image has no `authorized_keys`, `sshd` is not enabled, the variant file says `release`. A script does these checks (`scripts/vm-release-check.ps1` or `.sh`, named in the Outcome) and fails on a fixture or a `dev` image.
- [ ] A `release` build with a development-only unit added fails at build time (proof in the Outcome, reverted).
- [ ] Both base images are referenced by digest; the update recipe was run once (old and new digest in the Outcome).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; `scripts\free-space.ps1` after the builds.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: RUYA_VARIANT=release scripts/build.sh ; scripts/make-disk.sh qcow2
```

## Docs to update
- `docs/specs/01-platform.md` §3.7 (built, not planned), `docs/dev-setup.md`, `image/CLAUDE.md` (one rule: a new debug feature goes into the dev list), root `CLAUDE.md` only if a line can be replaced by the check.

## Hints
- The Dell stays on `dev` (it is driven over SSH).
- Two builds in one task: run them one after the other, in the background, never beside `dev.ps1 test` (WSL memory, LEAD-NOTES).

## Outcome
_Filled in by the implementer. First line: `Verified: vm`._
