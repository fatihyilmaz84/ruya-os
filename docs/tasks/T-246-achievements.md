# T-246 — Achievements: a console API for games, a per-profile service, and the unlock moment

Status: todo · Phase: 2 · Depends: T-245, T-164 · Area: api, services, shell, docs · Size: M · Owner: lead

## Goal
Games can award achievements; players see them per profile, with progress and a score; the console shows a clear "Achievement unlocked" moment (owner request, 2026-11-07). Today apps have no console API and Steam's achievements live inside Steam only. New service, app-facing API and design: owner: lead. Dependencies: T-245 (the profile-bus bridge and the notification kind: **one bridge for both**) and T-164 (apps must run for the real end-to-end test; the code and mock tests do not need it).

## Read first
- `docs/specs/03-services-and-apps.md` (`ruya-session`, profile managers, saves §4.5a, bus policies), `docs/specs/05-play-packages.md` (§3 layout, §4 manifest, the art slots and the importer's vetting of images, §4.5a data paths), `02-shell.md`, `04-design-system.md` §8
- T-245 (bridge design, notification kind, quiet mode), T-227 (UI sounds), T-215 (save backup set), T-210 (profile pages), `ruya-profiles` (the reference service), `docs/developers/`

## Scope
1. **Model (record the decisions in `03`):** an achievement has `id`, `name`, `description`, a `hidden` flag (name and text shown only once unlocked), `icon`, **points** in fixed buckets (5, 10, 25, 50, 100), an optional **tier** (our own names and art: no PlayStation or Xbox marks), optional **progress** (`progress_max` and a current value), `unlocked_at`. Per profile: unlocked list and progress per game, a total **score**, completion % per game. Local only in v1: no accounts, leaderboards, friends or sharing; private to the profile, never visible to other profiles, never in telemetry.
2. **Definitions** ship with the app, not in the service: `achievements.json` (versioned schema, validated, caps on size and count, icons by path inside the app's data, decoded and size-checked like the `.play` art slots). In a `.play` package a manifest key (for example `achievements`) points at the file; **add it to spec 05 §4 and its art-vetting list in the same commit** (the importer vets the icons; the shell never shows a raw file from a package). Read when the app is installed or updated (Store/Library hook) and on the first report. Unknown ids reported by an app are ignored and logged.
3. **App API:** a D-Bus portal `org.ruyaos.portal.Achievements` on the profile user's session bus (a Flatpak needs one `--talk-name`), methods `Unlock(id)`, `SetProgress(id, value)`, `List()`, `Reset` (dev builds only). The T-245 bridge forwards to the system service over `org.ruyaos.Achievements1` and adds **profile and app id from the bus peer credentials/cgroup** (an app cannot claim to be another app or profile). Rate limits; idempotency (unlocking twice is a no-op); progress is monotonic and capped.
4. **Service `ruya-achievements`** (Rust, pure core plus store, like `ruya-profiles`): files `/var/lib/ruyaos/achievements/<profile>/<app-id>.json` (root-only 0600, atomic writes), caps, deleted with the profile, **kept when an app is uninstalled** (like saves) and added to the save backup set (T-215). Signals `AchievementUnlocked(profile, app_id, id)`. Contract first: `org.ruyaos.Achievements1` (`ListGames(profile)`, `ListAchievements(profile, app_id)`, `GetSummary(profile)`; statuses), bus policy `ruya-shell` and root only, hardened unit. Write down: this is local data, an app can award itself; it is not for competition.
5. **Developer side:** a tiny helper library (a C header and a Rust crate, CC0/MIT, in `samples/`) wrapping the call with a no-op fallback when not on RuyaOS; the sample game (T-214) gets two achievements, one with progress; a new `docs/developers/` chapter "Achievements" (status planned until built, lint-checked).
6. **Shell:** (a) the **unlock moment**: a distinct toast through the notification centre (T-245 kind "achievement": name, icon, points; its own cue from the sound theme if T-227 exists, else the select sound), respecting quiet mode and "don't interrupt games" (a small corner toast while a game runs); it is kept in the centre. (b) **Profile page:** Settings -> Profiles -> you -> Achievements (score, games with completion %). (c) **Games and app pages:** a completion ring or "12 / 40" on the card and hero, an "Achievements" tab on the app page (locked and unlocked, progress bars, hidden ones as "Hidden achievement", sorted by unlocked-last or points). Empty states, Turkish, controller-first, focus asserted.

## Out of scope
- Imports (Steam's local stats cache; RetroAchievements is epic T-314), cloud or accounts, leaderboards, friends, sharing: Inbox items.

## Acceptance criteria
- [ ] Rust tests: schema validation and caps, Unlock idempotency, progress monotonic and capped, peer-credential attribution (an app cannot write another app's or profile's data), rate limits, store atomicity and modes, profile deletion, backup inclusion, privacy between profiles; bridge-core tests with fakes.
- [ ] QML tests (mock): the unlock toast in normal and "game running" modes, per-game list, hidden and progress, score and completion maths, empty states, focus asserted, controller-only.
- [ ] Screenshots (English and Turkish) against `04` §8.
- [ ] VM (lead run, needs T-164 for a real app): a Flatpak test app as a profile user unlocks through the portal; it shows for that profile only, survives a reinstall, appears in the T-215 backup set; the sample game demo. `scripts/vm-achievements-check.sh`.
- [ ] `lint-dev-docs.ps1` passes; `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `03` (service and portal), `05` §4 (the manifest key), `02`, the XML, `docs/developers/`, `dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
