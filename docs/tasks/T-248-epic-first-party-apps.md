# T-248 — EPIC: first-party RuyaOS apps (and the platform they need)

Status: blocked · Phase: 7 · Depends: — · Area: docs, shell, services, samples · Size: epic (not a build task; nobody implements it directly) · Owner: lead · Developer surface: none

**Blocked on owner decisions** (see "Owner-level decisions"): the app platform ADR (T-250) and the browser scope (T-258) are Proposed, and the owner picks which apps come first. The foundations (the HIG, the platform spike) can start earlier: they are a document and a spike.

## Goal
RuyaOS gets apps that we develop ourselves, **distributed separately** (their own Flatpaks from our `ruyaos` remote, **not baked into the image**), built to our **Human Interface Guidelines** and using the OS's components and APIs: a picture viewer, weather, a media player, a file manager, a Jellyfin client, a browser, emulator frontends. They also prove that the developer guide (T-214) is enough, and serve as examples that third parties copy. Request from the owner, 2026-11-07. Media and streaming apps stay out of the first MVP (owner, 2026-11-06, `00-overview.md` §2): this epic is the plan for after it, and the foundations are useful before.

## Children, in order

| Step | Task | What | Verifiable on this host |
|---|---|---|---|
| 0 | T-249 [lead] | `docs/specs/06-hig.md`: Human Interface Guidelines for app authors | yes (docs) |
| 0 | T-250 [lead] | Spike and ADR-015 (Proposed): how apps use the OS components (Flatpak runtime or extension, a RuyaKit QML module) | partly (VM) |
| 1 | T-251 | RuyaKit: extract the shared components into a module apps can use | yes |
| 1 | T-252 | App template, CI recipe, publish to the Store (base: `samples/hello-game`) | yes + VM (lead run) |
| 2 | T-253 | Picture viewer (small first app; proves T-251 and T-252) | yes |
| 2 | T-254 | Weather | yes |
| 3 | T-255 | Media player (local files; the codec situation recorded) | yes + VM |
| 3 | T-256 | File manager (storage browser, USB; nothing auto-runs from removable media) | yes + VM |
| 4 | T-257 | Jellyfin client (login by text input, direct play) | yes (mock server) |
| 4 | T-259 | Emulator frontend (launches separately installed emulator Flatpaks; no ROMs, no BIOS) | yes |
| 5 | T-258 [lead] | Browser: Proposed ADR-016 (engine, cursor-by-controller mode, scope), then the build | owner decision first |

## Dogfooding rule (ADR-022)
A first-party app uses **only the public surface** of `docs/developers/api-surface.md`: the Platform API, the data formats and the freedesktop portals the runtime ships, never a private RuyaOS service, a shell-only bus name or an extra Flatpak permission a third party could not get. If an app needs more, that is an Inbox line proposing the capability (the lead places it inside the approved list or writes a Proposed ADR), not a back door. The apps are the cheapest proof that the developer guide is enough; every child task carries this rule in its Hints.

## Overlap and dependencies with the other plans
- **`.play` packages (T-228..T-244):** a `.play` is how a *game* is packaged; first-party apps are ordinary Flatpaks from the `ruyaos` remote. They share the Store, the permission vocabulary and the HIG. T-259 must not duplicate T-239 and T-244 (runners): the frontend launches emulators that are separate Flatpaks or `.play` packages and never bundles one.
- **Platform APIs for apps** come from other tasks: notifications (T-245), achievements (T-246), play statistics (T-247), UI sounds (T-227), themes and wallpapers (T-209, T-208, done), the Session, Store and Devices APIs (spec 03). The ADR (T-250) lists which of them an app can call and what stays shell-only.
- **T-214 (developer guide):** the HIG is linked from it; the template reuses `samples/hello-game`.
- **T-164 and T-147:** an app's window only appears when per-profile Wayland sockets work: end-to-end tests of any app need T-164; code and mock tests do not.

## Owner-level decisions (Proposed ADRs; the lead does not decide them)
1. **ADR-015 App platform** (T-250): runtime or extension versus bundled sources versus a custom runtime; who maintains `org.ruyaos.Platform`; versioning against the shell.
2. **ADR-016 Browser** (T-258): the engine (QtWebEngine or another), its size and update burden, the password manager and permission scope, and whether a browser ships at all in the first release.
3. **Which apps, in what order**, and whether any of them is installed by default (an image-size and product-scope call).
4. **Legal note (emulators):** no ROMs, BIOS or firmware are shipped or linked to; emulators are separate Flatpaks the user installs. Confirm before T-259.

## Not planned yet
- More apps the owner may name (music, podcasts, game launchers); per-app update channels; an app-side telemetry SDK (none: T-224 covers the OS).

## Outcome
_Epic: nothing to implement here. The children carry the work; update the table as tasks finish._
