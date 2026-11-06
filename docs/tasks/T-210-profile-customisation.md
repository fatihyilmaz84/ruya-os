# T-210 — Profile customisation: avatar, colour, name and nickname

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell · Size: M · Owner: builder

## Goal
Each person makes their profile their own, the way every console and streaming app lets you: pick an avatar and a colour, set a name and a short nickname, and choose how the console starts (who is signed in). Owner request, 2026-11-06. Today a profile is an id, a display name, an automatically assigned colour, a role and an optional PIN (`Profiles1`: `ListProfiles` -> `a(ssssb)`, `CreateProfile`, `RenameProfile`, `SetPin`, `DeleteProfile`); the picker shows a coloured circle with the initial, and nobody can change the look.

## Read first
- `docs/specs/03-services-and-apps.md` §1 (profiles: one Unix user each, `profiles.toml` root-only 0600), `api/dbus/org.ruyaos.Profiles1.xml`, `services/ruya-profiles` (pure core, store, accounts), `services/CLAUDE.md`
- `shell/qml/ProfilePicker.qml`, `ProfileCard.qml`, `ProfilesPane.qml`, `ProfileAddFlow.qml`, `ProfileManageFlow.qml`, `Setup.qml` (first-boot profile), the `Profiles` facade and backends (D-Bus + mock), `shell/PATTERNS.md`
- `docs/specs/04-design-system.md` §3.7 icons (Material Symbols subset, how to add glyphs), §5 components, §8; root `CLAUDE.md` security invariants (PIN hashes never leave `ruya-profiles`)

## Scope
1. **What a profile holds (data model):** `name` (display name, 1-24 characters, as today), **`nickname`** (optional, 1-16 characters, the short name shown in toasts, the status pill and "You" lines; falls back to the name), **`avatar`** (an id from the built-in set, or `""` for the initial), **`color`** (one of a palette of 8 to 12 colours; the avatar's background and the profile's tint), `role` and PIN as today. Stored in `profiles.toml` with the other fields; defaults for existing profiles (initial + the colour they already have).
2. **Contract first:** make the record extensible: `ListProfiles` returns `aa{sv}` (keys `id`, `name`, `nickname`, `avatar`, `color`, `role`, `has_pin`) and an `UpdateProfile(actor_id, actor_pin, id, changes a{sv})` replaces `RenameProfile` (keys `name`, `nickname`, `avatar`, `color`); same authorisation as rename (the profile itself, or an admin with the admin PIN), same PIN-check statuses; `CreateProfile` takes the new fields (or defaults). Contracts are drafts until the first release: change the XML, the Rust service and its tests, the mock and the D-Bus client together. Validation in the pure core: trimmed, no control characters, length limits, names unique case-insensitively (status `name-taken`), unknown avatar/colour ids `invalid`; nothing secret ever appears in a reply.
3. **Avatars:** a built-in set of at least 24 avatars made of our own parts, licence-clean: a Material Symbols glyph (`pets`, `rocket_launch`, `sports_esports`, `music_note`, `star`, `bolt`, `palette`, `sports_soccer`, `local_pizza`, `skateboarding`, ... check each exists in the font and add them to the subset with `scripts/subset-icons.sh`, `lint-icons` stays green) on the profile's colour disc; one default avatar per new profile chosen at random so a household does not start with identical profiles. Each avatar has a name for accessibility ("Avatar: rocket"). The guest profile keeps a fixed avatar and cannot be customised. (Photos from a USB drive and illustrated avatar packs are a later step: Inbox.)
4. **Shell UI:** Settings -> Profiles -> a profile -> **Edit profile**: Name, Nickname, Avatar (a grid picker, the current one marked, controller-first), Colour (a row of swatches); the same fields in the Add-profile flow and the first-boot wizard's profile step (avatar and colour optional, random defaults). The picker, the status pill, the Guide overlay and toasts show the avatar; where a short label is needed they use the nickname if set. Existing PIN rules apply to editing (own profile: its PIN if it has one; admin edits others with the admin PIN). Translations in Turkish.
5. **Start-up behaviour:** a device setting "At start: ask who is playing (default) / sign in the last used profile automatically (only if it has no PIN)"; the picker still appears after Lock and when the last profile has a PIN. Stored in `DeviceSettings` (admin only).
6. **Mock and tests:** the mock mirrors the new contract; tests cover every rule above.

## Out of scope
- Photo avatars and downloadable packs, per-profile language/theme/wallpaper (need profile preferences: T-208/T-209 Inbox), age ratings and parental controls (Phase 3), profile ordering, profile import/export, a gamertag shared across devices, real-name/privacy settings, pronouns.

## Acceptance criteria
- [ ] Rust tests in `ruya-profiles`: `UpdateProfile` by the profile itself and by an admin (right and wrong PIN, lockout as for rename), a non-admin editing someone else is `not-allowed`, validation (length, control characters, duplicate names, unknown avatar/colour), defaults for existing records, the file stays 0600 and atomic, no PIN data in any reply.
- [ ] `tst_profiles*.qml`: the Edit profile flow changes name, nickname, avatar and colour (mock) and the picker and status pill update in place with focus kept; the nickname is used where a short label is needed and the name elsewhere; Add-profile and the wizard pick random distinct defaults; the guest cannot be edited; every picker is operable with the controller keys only, focus asserted after each move; the "sign in last used" setting skips the picker only for a PIN-less last profile.
- [ ] Screenshots: the picker with different avatars/colours, the avatar grid, the Edit profile page, the status pill with a nickname; English and Turkish; read against `04` §8 (legibility of each colour with white text, 24 px minimum).
- [ ] `vm-profiles-check.sh`: extended (lead run) with `UpdateProfile` over the real bus (rename, avatar, colour, a refused edit), the record shape, the `profiles.toml` mode; `Verified: host (vm pending: vm-profiles-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN; `lint-icons` green.

## Docs to update
- `Profiles1.xml`, `03` §1 (the data model and flows), `02-shell.md` (picker, Settings -> Profiles, the wizard), `04` §3.7 (the avatar glyph list), `docs/dev-setup.md` (the check).

## Hints
- Copy the structure of `RenameProfile` for authorisation and lockout so the PIN rules stay one code path.
- Keep the picker card size and focus ring as they are (`04` §4); the avatar replaces the initial inside the same disc.
- Colours: choose the palette so white text has >= 4.5:1 on each (compute, do not eyeball).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
