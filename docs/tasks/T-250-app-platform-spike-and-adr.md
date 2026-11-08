# T-250 — Spike and ADR-015 (Proposed): how apps use the OS's own components

Status: todo · Phase: 7 · Depends: — · Area: docs, shell, services · Size: M · Owner: lead · Developer surface: public-API

## Goal
Decide, with evidence, how a first-party (or third-party) app can use "our OS components": the design tokens, `FocusGlide`, `GlassPill`, cards, lists, dialogs, the on-screen keyboard hook and controller focus handling, plus the OS APIs. The result is a **Proposed** ADR-015 in `00-overview.md` for the owner to accept (an owner-level product and maintenance choice) and a recommendation. Owner request, 2026-11-07; part of T-248.

## Options to evaluate
- **A. A Flatpak runtime extension** `org.ruyaos.Platform` (the RuyaKit QML module, fonts, icons, sounds) on top of the Qt runtime that apps already use (check which `org.kde.Platform` versions exist and which Qt the shell uses), versioned separately from the shell.
- **B. A module bundled by each app** (the template copies RuyaKit; no shared runtime): simplest, larger apps, no shared fixes.
- **C. A full custom runtime**: only if A cannot work.

For each: size, the update flow through `ruya-store`, how a theme change (T-209) and the quality tier reach an app that runs sandboxed as a profile user (a portal, a settings file, an environment variable?), how focus and the Guide overlay cooperate, the work for an author and the maintenance cost for us.

## Scope
1. **Extraction audit:** which of `shell/qml` and `shell/src` can move to a module without forking (`Theme`, `Icon`, `GlassPill`, `FocusGlide`, cards, `HintBar`, `PrimaryButton`, lists, `TextEntry`, the controls) and what depends on shell singletons (`Session`, `Store`, `Audio`, `KeyRouter`): a table with the work per component. State what stays **shell-only** (the compositor, the Guide overlay, the Settings panes, the wizard).
2. **API audit for apps:** which D-Bus or portal APIs an app can reach from the Flatpak sandbox today (per-app Session info, Store, Devices battery and network state, the `org.freedesktop` portals), what T-245 (notifications), T-246 (achievements) and T-247 (statistics) add, and the permission each needs.
3. **A spike** of the recommended option with `samples/hello-game` or a tiny QML app on a Flatpak runtime in the VM: a themed window, a focused button moved by the controller, a theme switch seen from the app. Record numbers (size, start time).
4. **ADR-015 (Proposed)** with the options, the evidence, a recommendation and the consequences; an Inbox line; the epic updated; T-251 and T-252 rewritten to the decision once the owner accepts it.

## Out of scope
- Building RuyaKit (T-251), an SDK for other languages, a public developer programme.

## Acceptance criteria
- [ ] Audit tables for the components and the APIs, in an appendix of the ADR or in `docs/specs/06-hig.md`.
- [ ] The spike's results are in the ADR (what worked, what did not, numbers); the VM run is `Verified: vm` or marked pending.
- [ ] ADR-015 is *Proposed*; nothing in the repo depends on its acceptance yet.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): decide ADR-015 together with ADR-022: a runtime extension would also carry the `Platform1` client bindings and the stability tags; the spike names which public capabilities RuyaKit exposes (none of the shell-private ones).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`. Then: findings, files, the recommendation._
