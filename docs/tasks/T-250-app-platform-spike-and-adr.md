# T-250 — Spike for ADR-015 (Accepted): the `org.ruyaos.Platform` runtime extension and RuyaKit

Status: todo · Phase: 7 · Depends: — · Area: docs, shell, services · Size: M · Owner: lead · Developer surface: public-API

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** The audit tables go into an appendix of ADR-015, not into the HIG file (T-249 is not a dependency). The Platform1 client bindings inside the extension are built by T-251.

## Goal
Implement the owner's decision on how apps use the OS's own components: **ADR-015, Accepted (owner, 2026-11-08): a Flatpak runtime extension `org.ruyaos.Platform` carrying the RuyaKit QML module, versioned separately from the shell; not a module per app.** This task proves it works with numbers (extraction audit, API audit, a spike in the VM) and answers the open questions listed in ADR-015, so that T-251 (RuyaKit) and T-252 (template) can be written against facts. Owner request 2026-11-07; decision 2026-11-08; part of T-248.

## Decided (do not re-open)
- The shape is **A, the runtime extension**, on top of the Qt base runtime apps already use. B (a module each app bundles) and C (a full custom runtime) are no longer evaluated as alternatives; C is a fallback only if the spike proves A impossible, in which case you write a *Proposed* amendment to ADR-015, mark this task `blocked` with the question and stop (the owner decides).
- It is **versioned separately from the shell** and carries the `Platform1` client bindings and stability tags of ADR-022 (the public surface only; nothing shell-private).

## Questions to answer (the spike's job; the answers go into ADR-015 as amendments)
Which base runtime and Qt version the extension builds against, and how it stays compatible with Fedora's Qt in the shell (6.8 or newer; check which `org.kde.Platform` versions exist) · size of the extension and of an app that uses it · the update flow through `ruya-store` and the compatibility rule between app, extension and `RUYA_API_LEVEL` · how a theme change (T-209) and the quality tier reach an app sandboxed as a profile user (a portal, a settings file or an environment variable) · how focus, the Guide overlay and the on-screen keyboard cooperate with the app window · start time of a RuyaKit app in the VM · who builds and publishes the extension (the `ruyaos` remote, CI).

## Scope
1. **Extraction audit:** which of `shell/qml` and `shell/src` can move to a module without forking (`Theme`, `Icon`, `GlassPill`, `FocusGlide`, cards, `HintBar`, `PrimaryButton`, lists, `TextEntry`, the controls) and what depends on shell singletons (`Session`, `Store`, `Audio`, `KeyRouter`): a table with the work per component. State what stays **shell-only** (the compositor, the Guide overlay, the Settings panes, the wizard).
2. **API audit for apps:** which D-Bus or portal APIs an app can reach from the Flatpak sandbox today (per-app Session info, Store, Devices battery and network state, the `org.freedesktop` portals), what T-245 (notifications), T-246 (achievements) and T-247 (statistics) add, and how each becomes a `Platform1` capability (ADR-022, T-352) that the extension's client bindings wrap.
3. **A spike of the extension** with `samples/hello-game` or a tiny QML app on a Flatpak runtime in the VM: the extension builds and installs, a themed window, a focused button moved by the controller, a theme switch seen from the app. Record numbers (size, start time).
4. **Amend ADR-015** (it stays Accepted) with the answers, the evidence and the numbers; rewrite T-251 and T-252 to the findings; an Inbox line for anything the spike found; update the T-248 epic.

## Out of scope
- Building RuyaKit proper (T-251), an SDK for other languages, a public developer programme, the `Platform1` service itself (T-352; the spike may use a stub).

## Acceptance criteria
- [ ] Audit tables for the components and the APIs, in an appendix of ADR-015 or in `docs/specs/06-hig.md`.
- [ ] The spike's results (what worked, what did not, numbers: extension size, app size, start time) are in ADR-015; the VM run is `Verified: vm` or marked pending.
- [ ] Every question in the list above has an answer or an explicit "open, because".
- [ ] ADR-015 stays *Accepted*; T-251 and T-252 are rewritten to the findings.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): ADR-022 and ADR-015 are both Accepted (owner, 2026-11-08). The extension carries the `Platform1` client bindings and the stability tags; the spike names which public capabilities RuyaKit exposes (none of the shell-private ones).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`. Then: findings, files, the amendments to ADR-015._
