# T-251 — RuyaKit: the shared components as a module apps can use

Status: todo · Phase: 7 · Depends: T-250 · Area: shell, docs · Size: M · Owner: builder · Developer surface: public-API

## Goal
The design tokens and the building blocks that apps need move into a QML module (working name **RuyaKit**) that both the shell and first-party apps use, so an app looks and behaves like the shell without copying it. The shape is decided: **ADR-015, Accepted (owner, 2026-11-08), a Flatpak runtime extension `org.ruyaos.Platform` that carries RuyaKit and is versioned separately from the shell** (not a module per app); the spike T-250 supplies the details (base runtime, Qt version, theme delivery) as amendments to the ADR; this task builds what the ADR says. Part of T-248.

## Read first
- ADR-015 and the audit tables of T-250; `docs/specs/04-design-system.md` §8 (a new token or component comes with the spec update); `docs/specs/06-hig.md` (T-249); `shell/CLAUDE.md`, `shell/PATTERNS.md`; `shell/CMakeLists.txt` (the `ruyashell` module)
- T-209 (themes as data), T-204 and T-205 (glass layers, the glide), T-227 (sounds) for what must stay themeable

## Scope
1. Extract, without forking (the shell imports the same module; no copy), the components the audit marks as portable: `Theme` and the theme sets, `Icon` and the icon font, `GlassPill`, `GlassLayers`, `FocusGlide`, cards and art, `HintBar`, `PrimaryButton` and `SecondaryButton`, list and setting controls, `TextEntry` with the on-screen keyboard hook, controller focus handling. Anything that depends on a shell singleton gets an interface (a property or a small adapter) instead of an import.
2. **How an app learns the theme and the quality tier** as the ADR decides (portal, settings file or environment): the module reads it and follows changes.
3. A **gallery app** inside the repo (not shipped): every component, every theme, focus movement, reduced motion; it is the test bench and the screenshot source.
4. Versioning: the module has an API version; breaking changes are listed in a changelog in `docs/developers/`.
5. Docs: a RuyaKit chapter in `docs/developers/` (component list with a screenshot each, how to use it); the specs updated.

## Out of scope
- Shell-only parts (compositor, Guide overlay, Settings panes, wizard), a non-QML toolkit, an app template (T-252).

## Acceptance criteria
- [ ] The shell builds and `dev.ps1 test` and `shots` stay green with the shell importing the extracted module; no test weakened.
- [ ] Gallery tests: every component renders in all themes and tiers, focus and keys behave as in the shell, reduced motion holds, the theme follows a change.
- [ ] A component used by both the shell and the gallery has one source file.
- [ ] `lint-dev-docs.ps1` passes for the new chapter; screenshots read against `04` §8.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): RuyaKit is what third parties build on. Missing: a chapter in `docs/developers/`, a sample using only RuyaKit, API-level declaration (T-351).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
