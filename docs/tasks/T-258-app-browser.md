# T-258 — First-party app: Web browser (Proposed ADR-016 first)

Status: todo · Phase: 7 · Depends: T-250, T-252 · Area: docs, apps · Size: L (split after the ADR) · Owner: lead · Developer surface: none

## Goal
A browser for the couch: open pages, search, watch web video, with a controller. It is the biggest and riskiest app in T-248: an engine is large, needs constant security updates and handles untrusted code. So the **first deliverable is a Proposed ADR-016 for the owner**, then (only if accepted) a build task split from this one. Own Flatpak (`org.ruyaos.Browser`) if built.

## Read first
- T-248, `docs/specs/06-hig.md`, ADR-015 (T-250), `docs/specs/00-overview.md` (scope; "web-app runtime" is deferred there), `docs/developers/permissions-and-sandbox.md`, T-220 (privacy settings), T-224 (telemetry: none from the browser)

## Scope (the ADR)
1. **Options with evidence:** (a) **Qt WebEngine** (Chromium inside Qt: our toolkit and RuyaKit fit, but its size, build time and security-update cadence are large, and a Flatpak runtime must carry it: check `org.kde.Platform`'s WebEngine base app and its update policy), (b) a **Flatpak of an existing browser** (Firefox, GNOME Web, Chromium) wrapped by a launcher and a controller-cursor mode, which makes us a distributor not a developer, (c) **no browser** in the first release, with a "web app" shortcut model deferred. For each: size, security-update responsibility (who patches within what time), controller input (a virtual cursor mode with snap-to-links versus focus navigation; on-screen keyboard), video (hardware decode, DRM not planned), the permission model (camera, microphone, location off; downloads to a folder; no password manager at first), and the maintenance cost.
2. **A spike** on the recommended option in the VM: load a page, scroll and click with the controller, play a web video, measure memory and size.
3. **Recommendation and consequences** written as ADR-016 *Proposed*; an Inbox line; split this task into build tasks (engine app, cursor mode, bookmarks and history per profile with "clear my activity" (T-247, T-220), permissions, downloads, update channel) after the owner accepts.

## Out of scope until the ADR is accepted
- Any build of the browser, extensions, sync, passwords, DRM, a default-search deal (owner-level and legal).

## Acceptance criteria
- [ ] ADR-016 is written with the options, the spike numbers and a recommendation, marked *Proposed*; the owner's decision is requested in `STATUS.md` (Open owner decisions) and nothing is built before it.
- [ ] If accepted: build tasks exist with acceptance criteria, including a security section (update cadence, sandbox, content-security tests with hostile pages) and the HIG checklist.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): none. Dogfooding rule: this app may use only the public surface; if it needs something else, add an Inbox line proposing the capability, do not use a private service.

## Outcome
_Filled in by the lead. First line: `Verified: host | vm | unverified`._
