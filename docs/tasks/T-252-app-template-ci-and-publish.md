# T-252 — App template, CI recipe and publishing to the Store

Status: todo · Phase: 7 · Depends: T-250, T-251, T-214 · Area: samples, ci, docs · Size: M · Owner: builder · Developer surface: public-format

## Goal
Anyone, and every first-party app of T-248, starts from one template that builds, themes itself like the shell, follows the HIG and ends as a signed Flatpak on a Store remote. Base: `samples/hello-game` and the guide's `publishing.md`. Part of T-248.

## Read first
- `docs/developers/` (`getting-started.md`, `publishing.md`, `testing-and-debugging.md`), `samples/hello-game/`, `docs/specs/06-hig.md` (T-249), ADR-015 (Accepted: the `org.ruyaos.Platform` runtime extension; details from the spike T-250) and RuyaKit (T-251); `scripts/lint-dev-docs.ps1`; the `ruyaos` remote and `ruya-store` (spec 03)

## Scope
1. **Template** `samples/app-template/`: a minimal QML app (CC0), the Flatpak manifest, AppStream metadata with the `x-ruya-*` keys and OARS, icons, a controller-navigable first screen built from RuyaKit, a Turkish translation example, a unit test, a README linking the HIG checklist.
2. **CI recipe:** a GitHub Actions workflow (reusable file in the template) that builds the Flatpak with `flatpak-builder`, runs the app's tests and the HIG checks that can be automated (focusable elements named, contrast of the tokens used, no literal colours), lints the metadata with `appstreamcli validate`, and signs and publishes to a Flatpak repository. The signing key is a CI secret and never in the repo (security invariant).
3. **Publishing path** to the `ruyaos` remote: what a first-party app does (our repository, our key) and what a third party does (a developer remote or Flathub); the review step is an owner-level process and is only described, not built.
4. **Developer chapter** "From template to Store" in `docs/developers/`, lint-checked; the template builds with the guide's commands.

## Out of scope
- The remote's review pipeline (owner-level), per-app update channels, a telemetry SDK.

## Acceptance criteria
- [ ] The template builds with `flatpak-builder` in WSL and `appstreamcli validate` passes; its unit test runs in `dev.ps1 test` or its own gate.
- [ ] The CI workflow lints (act or a dry run on the host; the first real run is a lead run on GitHub) and contains no secret.
- [ ] VM (lead run): the built Flatpak installs through `ruya-store` from a local repository, launches for a profile (needs T-164 for a window) and shows the themed first screen.
- [ ] `lint-dev-docs.ps1` and `.\scripts\dev.ps1 test` pass.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): the template is the sample for every public capability; it may use only the public surface and declares `x-ruya-min-api-level` (T-351).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
