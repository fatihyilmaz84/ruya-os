# T-382 - GE-Proton preinstalled in the image, updated through the Store, named in About

Status: todo · Phase: 5 · Depends: T-381 · Area: image, services (ruya-store), shell (About) · Size: M · Owner: builder · Complexity: complex · Developer surface: internal

**ADR-032 (stores, 2026-11-10):** the `ruyaos` remote this task needs is the official store (`docs/specs/10-stores.md`); its hosting and key are T-444's decisions.

## Goal
A fresh install has GE-Proton ready offline from the first boot; the Store updates it to newer pinned releases without an OS update; Settings > About lists it with its licences.

## Read first
- `docs/specs/00-overview.md` ADR-025 (as updated by T-381) and the T-381 Outcome (extension name, branch, build recipe, size)
- `docs/specs/03-services-and-apps.md` (Store, remotes, preinstalled Flatpaks), `docs/specs/01-platform.md` (image contents), `image/CLAUDE.md`
- T-195 (image size), the About pane and its notices (`shell/qml/`, `PATTERNS.md`)

## Scope
1. The extension build: a script that turns the pinned upstream release (URL and SHA-256 in one checked-in file) into the Flatpak extension; the image installs it into the system installation at build time (no download at boot).
2. Updates: the Store sees the extension as updatable (the remote T-381 picked); an update replaces it atomically; the previous branch stays until no game uses it (or say why not).
3. About: a "Windows compatibility" row (GE-Proton version) and the licence notices T-381 listed; the source offer text.
4. Size: the image grows by no more than T-381's measured number plus 10 %; `check-image-manifest.sh` knows the extension.

## Out of scope
- Steam's default (T-383), the developer chapter (T-384), `.play` resolution (T-239).

## Acceptance criteria
- [ ] VM (this task): `scripts/vm-runner-check.sh` (new): the extension is installed, its `runner.json` parses, a Windows test program (`.exe` that prints a line) runs through it as a profile user and exits 0, offline; `RUYA_BOOT_OK`.
- [ ] Store: an update of the extension from an older pinned branch to a newer one (test on the mock: `tst_store` case; in the VM: the check above with a second branch).
- [ ] About row and notices: a QML test and a reviewed screenshot (en, tr).
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Hints
- The owner's codec answer (ADR-025 open question 2) decides whether the build strips the media pieces: do not build before it is in ADR-025.

## Outcome
_Filled in by the implementer._
