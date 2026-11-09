# T-244 — System runner pack: Wine as a Flatpak extension on the `ruyaos` remote

Status: done · Phase: 7 · Depends: T-229, T-239 · Area: image, services, docs · Size: M · Owner: lead

## Goal
`source: system` and `newest` have something to resolve to: a Wine runner (with DXVK and VKD3D-Proton) published as a Flatpak extension, one branch per Wine major, installable from the Store, updated independently of the OS, shared by all packages. The size/preinstall question (owner D3) is answered with a measured number.

## Read first
- `docs/specs/05-play-packages.md` §6.2, §6.4, §14 (licensing); T-229 Outcome (display path, extension mechanics); T-239 (`runner.json` contract and discovery)
- `docs/specs/03-services-and-apps.md` §4.2 (remotes; the `ruyaos` remote does not exist yet), T-195 (image size), the owner decisions in STATUS (preinstalled runtime size)

## Scope
1. Build recipe (Flatpak manifest in `image/` or a new `packages/` directory; check where other build recipes live) for `org.ruyaos.Play.Runner.Wine//<major>` from a pinned upstream Wine release plus pinned DXVK and VKD3D-Proton, with checksums, a `runner.json`, and licence texts and the written source offer under the extension's `licences/` (SBOM entry via `syft` like the rest, 03 §7).
2. The `ruyaos` remote: decide hosting for the dev loop (a local repo served over HTTP in the VM/test, and the documented plan for the real one), key handling (signing key never in the repo or image), and **preinstall the Wine runner in the image** (owner decision D3, 2026-11-06: preinstalled, so Windows packages with `source: system` work offline from first boot); report the image and update size cost in the Outcome, and keep a build argument that leaves it out for size experiments.
3. `ruya-play` learns to offer "Install the Wine runner" when `source: system` has no match (`Install` returns `needs-runner` with the runner id; the shell offers it; installation goes through `Store1`).
4. Size and time numbers for the Outcome: extension size, install time on the VM, first-launch time of the sample, delta of the image if preinstalled.

## Out of scope
- Proton, emulators, GPU-vendor specific tweaks, running the official remote in production, automating Wine upgrades.

## Acceptance criteria
- [ ] The build is reproducible from the repo with pinned checksums; a checksum mismatch fails it (negative test in the script's self-check).
- [ ] `scripts/dev.ps1 test` includes a licence/SBOM lint covering the extension recipe (all components listed with SPDX ids).
- [ ] VM (this task): image with the remote; `vm-play-check.sh runner`: the Wine sample (T-243) with `source: system` and no bundled Wine installs, is offered the runner, fetches it from the dev repo, starts, and a second package bundling the same Wine files shares disk (OSTree object count or `du` evidence recorded); with `newest`, bundled older Wine loses to the extension and a newer bundled one wins.
- [ ] Offline: with the runner missing and no network, a `system`-only package refuses at install with the right status; a `prefer-system` package with a bundled copy installs and runs.
- [ ] `dev.ps1 test` ALL GREEN; `free-space.ps1` after the build.

## Verification
VM build and check (background).

## Docs to update
- Spec 05 §6.4 and D3; spec 03 §4.2 (remote table), `docs/image-packages.md`, `docs/dev-setup.md`, STATUS decisions.

## Outcome
Verified: unverified

Dropped: merged into T-385 (lead-8, 2026-11-09). ADR-025 (owner) makes GE-Proton the preinstalled default and Wine one of several Store runners; T-385 builds the whole runner catalogue with T-382's script, including this Wine pack.
