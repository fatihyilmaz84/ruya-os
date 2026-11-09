# The public surface of RuyaOS

What an app may rely on, what it may not, how the console will open more, and how a change to the public surface is made safely. This chapter is the charter behind `docs/developers/`: a feature is **documented here or it is not public**.

*Status: **Accepted** (ADR-022 in `docs/specs/00-overview.md`, owner, 2026-11-08, approved as drafted: the tier-B list below, the never-public list, and stability promises only from the first release). The Platform service that opens tier B is planned (T-352), so nothing in tier B can be called yet. The apps reach the client bindings through the `org.ruyaos.Platform` runtime extension (ADR-015, Accepted the same day; spike T-250). Everything public is **experimental** until the first release: names, arguments and behaviour may change without notice.*

## Why a charter

Every D-Bus service of the console answers only the shell and root. That is deliberate: a game must not be able to read a PIN hash, install an app or change the update channel. But games and apps do need a few console features (achievements, notifications, save and pause hooks), and each feature that arrives on its own opens its own door. The charter decides once which doors exist, who may use them and how each is documented and tested.

## Three tiers

| Tier | What | Who can use it | Today |
|---|---|---|---|
| **A, shell-private** | Profiles (PIN, admin), Store, Update, Devices administration, Telemetry configuration, the compositor | the shell and root only; the bus policy stays "shell and root" | as built |
| **B, the Platform API** | a short list of capabilities (below) behind one service, `org.ruyaos.Platform1` | a sandboxed app, per app and per profile, only what the player allowed | **planned** (T-352) |
| **C, data-only formats** | files with a documented layout; no code runs | anyone, no permission needed | partly built |

Rules that hold for every tier-B capability:

- **One door.** A sandbox gets one bus permission (`--system-talk-name=org.ruyaos.Platform1`). The service behind it identifies the caller (the Flatpak app id and the profile), looks up the per-app permission the player set in Settings > Privacy, rate-limits, sanitises every string and size, and forwards to the private services. The private services stay private.
- **Least privilege and per profile.** The caller's identity decides, never an argument. An app sees only its own data and the active profile's; nothing leaks between profiles.
- **Read-only unless the capability is about the app's own data.** An app never writes a setting of the console.
- **A malicious app is the test case.** Every capability has abuse tests: flood, oversized and malformed input, another app's id, a profile that is not active, a call while the app is not running.
- **Deprecation before removal**, see Versioning.

## The tier-B list (approved by the owner, 2026-11-08)

Anything not on this list needs a new line in ADR-022 first (the owner's approval). "Missing" means the doc, sample, mock or conformance piece no task owns yet.

| Capability | What an app can do | Task | Missing |
|---|---|---|---|
| Lifecycle | learn "going to background / frozen / closing", answer "save now" within the 5 s | T-279, T-275 | mock, sample, conformance, chapter update (`fullscreen-and-lifecycle.md`) |
| Achievements | unlock, set progress, list its own | T-246 | mock for off-device tests, conformance; re-seat on `Platform1` (T-246 designs its own portal) |
| Play statistics, presence, now-playing | report what is played (game, system, state), read its own history | T-247 (the ledger, built, private), T-306 | the app-facing call is only in T-306; a presence/report sample and chapter are missing |
| Notifications | post, update, withdraw; actions; kept in the notification centre | T-245 | chapter, sample, mock, conformance |
| Controller input extras | player slot of a pad, rumble, battery | T-217, T-264, T-266 | no D-Bus half is planned (slots reach apps only as ordered virtual pads); rumble/battery API, chapter update (`controller-input.md`), sample |
| Text input | ask for the on-screen keyboard and get the text | none | whole capability (an `org.freedesktop.portal`-style call or a text-input protocol): unplanned |
| Display information | read the resolution, refresh rate, safe area, HDR state | none | whole capability, read-only: unplanned |
| Theme accent | read the accent and the light/dark/glass state to match the shell | none | whole capability, read-only: unplanned |
| Age rating and parental respect | read "this profile's age limit" to hide content in the app | none (T-211 has the limits, private) | whole capability, read-only flag: unplanned |
| Storage picker | choose a file or folder on the console or a USB drive | none (portal backend gap, `03` §4.4) | whole capability: unplanned |
| Content provider (owner, 2026-11-10, ADR-031) | publish its own items (episodes, albums, slots) with progress for Home's "Continue watching" and the console search; open the app at an item | T-420 | whole capability: planned |
| Game data hub | where ROMs, saves, states, captures live; identify a file; read now-playing/captures with a permission | T-302..T-308 (ADR-020) | re-seat as a `Platform1` interface; T-308 owns the chapter and sample |

The list is approved, so the lead may now plan the unplanned capabilities (text input, display information, theme accent, age rating, storage picker) as tasks inside the charter; each is `Developer surface: public-API` with the Definition of done below. Nothing outside the list is planned without a new ADR line.

## Never public

Profiles, PINs and admin actions; update and rollback; installing, uninstalling and permission overrides; writing any system setting (display mode, network, audio routing, power); telemetry; the shell's own state. If an app needs one of these, the answer is a portal-style *request* that the shell shows to the player (the player decides in the shell), never a call that acts.

## Tier C: data-only formats

No code, so no bus permission, and the safest way to extend the console. The format is public once its chapter says so:

| Format | Where described | State |
|---|---|---|
| Save, state, config and cache layout under `~/.var/app/<id>/` | [Saves and data](saves-and-data.md), `03` §4.5a | public, written |
| AppStream keys (`x-ruya-*`, content rating, controller support) | [AppStream metadata](appstream-metadata.md) | public, written |
| Sound themes (cues, ambient bed) | [Sound themes](sound-themes.md) | public, written, checker built |
| `.play` packages | `05-play-packages.md` (epic T-228) | parked by the owner |
| Theme, wallpaper and icon packs | none | unplanned |

## How a public thing is made

1. **Planning.** Every task header carries `Developer surface: none | internal | public-API | public-format` (default `none`; `docs/tasks/PLANNING.md`). The lead (as planner) sets it when the task is written; a missing field means `none`, and done tasks and tasks in flight are not changed. The owner approves only the capability **list** above, once; the lead places tasks inside it, and anything outside needs a Proposed ADR. A builder never decides or widens the surface: when a change, whatever the header says, touches a contract an app could reach, the builder tags it `experimental` and writes `possibly public: <what>` in the HANDOFF, and the lead decides at merge and writes the follow-up task.
2. **Contract first.** The D-Bus XML of a public method, signal or property carries the stability tag and a documentation annotation:

   ```xml
   <method name="Unlock">
     <annotation name="org.ruyaos.Stability" value="experimental"/>
     <annotation name="org.ruyaos.Since" value="1"/>
     <arg name="id" type="s" direction="in"/>
   </method>
   ```

   `Stability` is `experimental`, `stable` or `deprecated`; `Since` is the API level that introduced it. An element without the tag is private. Contracts stay drafts until the first release (root `CLAUDE.md`).
3. **Definition of done adds** (on top of the root list): a paragraph in the right chapter of this folder, a minimal sample that `scripts/lint-dev-docs.ps1` compiles or runs against the mock (T-350, T-353), mock support so a developer can test off the console, and a conformance test that calls every public element, including the abuse cases.
4. **Who does it.** The builder who implements the task writes the code, the chapter paragraph and the sample in the same commit; that is the cheapest moment and the author knows the behaviour. The builder is **not the only check**: `ruya-api-reviewer` (read-only, Sonnet, `.claude/agents/`) reads every diff that touches a public XML or this folder (and, as a backstop, any diff that touches app-reachable XML, a bus policy or Flatpak permissions even when the header says `none`, flagging the mismatch), for least privilege, abuse cases, per-profile privacy, naming and consistency, back-compatibility and documentation coverage. Before each release `ruya-devdocs-auditor` follows this guide as a new developer would (build the sample, call each documented API on the mock or the VM) and reports gaps as Inbox lines. The lead decides on the findings.
5. **Dogfooding.** A first-party app (epic T-248) may use **only** the public surface. If it needs something that is not public, that is an Inbox line proposing the capability, not a private back door. A first-party app is the cheapest proof that the documentation is enough.

## Versioning

- **API level.** One integer, `RUYA_API_LEVEL`, in `/usr/lib/os-release` (and `/etc/os-release`). It rises when a public element is added or changed. An app reads it at run time (or asks `Platform1`) to use a newer feature when present.
- **Minimum level in metadata.** An app declares the lowest level it needs in its AppStream file (`x-ruya-min-api-level`, planned: [AppStream metadata](appstream-metadata.md) has the other `x-ruya-*` keys). The Store hides an app whose minimum is above the console's level and says why on its page; an installed app that no longer fits is flagged, not removed.
- **Changelog from the XML.** A script diffs the public elements of two versions of `api/dbus/*.xml` and lists added, changed and deprecated elements by level; the release notes embed it (T-351).
- **Deprecation.** After the first release: additions are allowed within a level; a change or removal needs `deprecated` for at least two levels first, a line in the changelog and a developer-guide note. Before it, everything is *experimental* and changes freely, but a change is still written to the changelog.

## What is public today

Nothing in tier B. In tier C: the layouts and keys in the table above. Everything else that this guide mentions (the Guide button, the 5-second `SIGTERM` window, the freedesktop portals the Flatpak runtime ships) is behaviour of the platform, documented in its own chapter.

## Retrofit audit of the open tasks (2026-11-08)

One-time audit by the lead: T-245 to T-247, T-262 to T-268, T-217, T-248 to T-259, the hub, retro-achievement, saves, play-package and multitasking tasks, and the todo tasks that touch app-reachable behaviour. Each open task below now has a `Developer surface:` field in its header; where a doc, sample or mock piece is missing, its Hints say so.

| Task | Surface | Missing doc / sample / mock |
|---|---|---|
| T-245 notifications | public-API | chapter, sample, mock for developers, conformance |
| T-246 achievements | public-API | mock for off-device tests, conformance; reconcile its own portal with `Platform1` |
| T-247 play statistics (done) | internal | the app-facing half is T-306 |
| T-279, T-275 lifecycle | public-API / internal | chapter update, sample, mock, conformance |
| T-217 virtual gamepad | public-API (evdev) | chapter update, sample |
| T-262 wake by controller | internal | none |
| T-263 spec, T-264 registry, T-265 UI, T-267, T-268 | internal / none | none (not seen by apps) |
| T-266 virtual pads per slot | public-API (evdev) | `controller-input.md` update, sample reading pad order, conformance |
| T-248 epic and apps T-253..T-259 | none | the dogfooding rule is added to T-248; T-259 uses the hub, not private services |
| T-250 platform spike (ADR-015) | public-API | ADR-015 Accepted (the `org.ruyaos.Platform` runtime extension carries the client bindings); the spike answers the open questions |
| T-251 RuyaKit | public-API | chapter and sample if it is a runtime extension |
| T-252 app template | public-format | none (it is the sample) |
| T-302 hub epic, T-304 `GameData1`, T-306 now-playing | public-API | re-seat behind `Platform1`; T-308 owns chapter and sample |
| T-305 captures, T-311 saves for external emulators | public-API | chapter paragraph, conformance |
| T-309, T-310 saves manager | internal / none | none |
| T-316 RA hand-over | public-API | what an emulator is handed is a contract: chapter, sample |
| T-228 `.play` epic, T-230, T-233, T-243 | public-format | covered by T-243 once unparked |

## Sources

Checked on 2026-11-08 against: `docs/specs/00-overview.md` (ADR-015 and ADR-016 are Accepted since 2026-11-08; ADR-017, ADR-020 and ADR-022), `docs/specs/03-services-and-apps.md` §4.4 to §4.6, `docs/tasks/PLANNING.md`, `.claude/agents/ruya-api-reviewer.md` and `ruya-devdocs-auditor.md`, and the open tasks named in the audit. Nothing described as planned here exists yet.
