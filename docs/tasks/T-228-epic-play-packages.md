# T-228 — EPIC: `.play` packages (self-contained games and apps)

Status: blocked · Phase: 7 · Depends: — · Area: docs, api, services, shell, image · Size: epic (not a build task; nobody implements it directly) · Owner: lead · Developer surface: public-format

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Stale since ADR-025: "Wine is the one system runner and the image preinstalls it". GE-Proton is preinstalled and the default; the runner set is T-382/T-385.

**Parked by the owner (2026-11-06).** ADR-014 is accepted (conditional on the T-229 spike), D2 and D3 are decided (RuyaOS ships no emulators, Proton, firmware or discs; Wine is the one system runner and the image preinstalls it), but the owner wants the current visual-polish lanes and T-164 first. No child task starts and no `.play` code is written until the owner says to start; then the lead sets this task `done` ("epic released") and the children become eligible by their own dependencies.

**Stores and review (2026-11-10, ADR-032):** read `docs/specs/05-play-packages.md` section 18 before any child task starts: it corrects the draft (stores carry `.play` files and the console imports them, T-446; one Flatpak transaction queue; sideloading needs an admin; prefix templates, link chains and discs do not fit the format yet; kept saves and a different key). T-230 fixes section 18 C in the schema, T-231 items 16 to 19, T-229 items 5 and 20.

## Goal
A developer can build one folder or one `.play.zip` that holds a game (native, Windows under Wine or Proton, or an emulated title), the runner it needs or a pointer to the OS's, art, video, metadata, links, a permission request and update information. A player puts it on a USB stick or downloads it, sees it on the console with its art and permissions, installs it by controller, plays it in a Flatpak sandbox, and it updates safely. Owner request, 2026-11-06.

## The design
`docs/specs/05-play-packages.md` (the whole design, read it first), ADR-014. In one paragraph: a `.play` is a **container, not a runtime**: `play.json` (metadata, run, components, closed permission vocabulary, data, update), `play.files` (every file's SHA-256; links and modes as data), `play.sig` (Ed25519, one signature covers all), `art/`, `payload/`, `components/`. Installing imports it as a system Flatpak app `play.<id>` through an unprivileged, network-less unpack helper and a small root commit step; runners (Wine first) are Flatpak extensions on the `ruyaos` remote; the Store is the update channel for Store packages, an opt-in signed feed for sideloaded ones.

## Children, in order

| Step | Task | What | Verifiable on this host |
|---|---|---|---|
| 0 | T-229 [lead] | Spike: does import-as-Flatpak work; Xwayland vs Wine Wayland; Proton nesting | VM only |
| 1 | T-230 | Format crate, JSON schema, hostile-package fixtures | yes |
| 1 | T-231 [lead] | Signing, trust tiers, key continuity, revocation (pure core) | yes |
| 1 | T-232 | Art and video vetting core (decode, check, re-encode) | yes |
| 2 | T-233 | `ruya-pack` developer CLI | yes |
| 2 | T-234 | `Play1` contract, mock, shell client | yes |
| 2 | T-235 [lead] | Design step: package page components | yes |
| 3 | T-236 | Shell: Install from USB and the package page | yes (mock) |
| 3 | T-237 | Importer core: staging, unpack, verify, commit trait + fake | yes |
| 4 | T-238 [lead] | `ruya-play` service in the image | VM (this task) |
| 4 | T-239 [lead] | Launcher and runner resolution | VM (lead run) |
| 4 | T-240 | Permission mapping, ceilings, admin gate | yes + VM (lead run) |
| 5 | T-241 [lead] | Updates: feeds, key continuity, rollback | yes + VM (lead run) |
| 5 | T-242 | Library, Home hero, preview loop, saves paths | yes |
| 5 | T-243 | Developer guide chapter and two sample packages | yes |
| 6 | T-244 [lead] | System runner packs (Wine) on the `ruyaos` remote | VM |

Steps 1 to 3 can be built and verified on Windows with mocks; steps 4 to 6 need the Linux image (T-229's answers decide their final shape; the lead updates the affected task files and spec 05 after T-229).

## Not planned yet (each needs an owner answer or a prior task; each becomes an Inbox line when it matters)
- Documenting Proton as supported when a packager bundles it (Q3; depends on T-229). RuyaOS ships no Proton, emulators or firmware (owner, 2026-11-06): packagers bundle them, so there is no emulator or Proton runner task for RuyaOS itself.
- The Official remote's review and CI pipeline that converts a submitted `.play` into a signed ref (publishing process: owner-level).
- Delta updates (05 §11), a `.play.tar.zst` form, out-of-process video playback (Q5), several launch entries per package, per-profile private installs (Q7).

## Definition of done for the epic
A sample Windows game packaged as `.play` with `source: newest` installs from a USB stick by controller on the VM and the Dell, shows its art, runs under the OS's Wine inside the sandbox with a controller, keeps its saves across an update and a rollback, refuses a tampered copy and a copy signed by another key, and the developer guide lets an outsider repeat it. (Hardware part: B-002.)

## Outcome
_Filled in by the lead when the epic closes._
