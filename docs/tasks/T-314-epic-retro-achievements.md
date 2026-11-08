# T-314 — EPIC: retro achievements (RetroAchievements) for emulated games

Status: todo · Phase: 5 · Depends: — · Area: docs · Size: M · Owner: lead

## Goal
A player who plays retro games through an emulator earns, sees and keeps RetroAchievements (retroachievements.org) the same way as the console's own achievements (T-246): one account link per profile in Settings, the emulator logged in without typing a password on a TV, the unlock moment shown by the console, progress and completion in the Library and on the profile page. Owner request, 2026-11-08: "there is an epic for retro rom support, lets also think about retro achievement support." Builds on the game data hub (T-302) and the native achievements (T-246).

## What exists (checked 2026-11-08, from the backlog and spec files)
- Planned: T-246 native achievements (model, per-profile service, unlock toast, profile page; its Out of scope names "RetroAchievements for emulator apps" as an Inbox item: this epic is that item), T-302 hub (`Identify(file)` = stable game id by content hash, `Report` now-playing, `Paths`), T-259 emulator frontend, T-217 controller mapping per system, T-220 per-app permissions, T-245 notification bridge, T-211 child profiles.
- Missing (this epic): an account link, a place for the token, a way to hand it to emulators, the RA data in the shell, the unlock moment for emulator unlocks.

## Facts the design starts from (public knowledge, **verify against retroachievements.org docs and the rcheevos repository before relying on them**: unverified here, no network use in this planning pass)
- RetroAchievements is a community service; a user has an account; achievement sets belong to a game **identified by a hash of the ROM** (a per-console hashing rule); sets are written by volunteers. Emulators and cores unlock achievements by watching emulated memory through the open-source `rcheevos` runtime (MIT, to be confirmed) and report to the site; RetroArch (and several standalone emulators) already do this when the user logs in inside the emulator.
- A **hardcore mode** exists: achievements count as hardcore only without save states, cheats, rewind or slow motion. The emulator enforces it, not the OS.
- There is a web API (user profile, recent unlocks, game progress, achievement lists) used with the user's name and a key; the login in an emulator exchanges the password for a token so the password is not stored.

## Model (proposed; ADR-021 Proposed in `00-overview.md`)
1. **The OS is not an emulator.** It never runs `rcheevos` against a game itself in v1: the emulator does the detection and talks to the site. The OS owns: the **account link per profile**, **handing credentials to opted-in emulators**, **showing the data**, and **showing the unlock moment**.
2. **Account link** (Settings > Profiles > you > Achievements > Retro): username plus password typed once with the on-screen keyboard, or a token created on the phone (QR code to the site's settings page); only the **token** is stored (root-only, per profile, like other secrets; never in the shell process, never in logs, never in backups unless the player ticks it); unlink deletes it. The profile PIN rules apply (T-211): off by default for child profiles.
3. **Hand-over to emulators:** the hub gives an opted-in emulator the profile's RA username and token at start (a per-app permission "RetroAchievements account" in T-220, asked on first use, revocable) and the recipe for RetroArch (`cheevos_enable`, `cheevos_username`, `cheevos_token`, `cheevos_hardcore_mode_enable`, in the profile's config; the first-party frontend T-259 does it for the player). Emulators the OS does not know get nothing.
4. **Show the data:** the shell reads the player's RA profile and progress through a service that caches it (offline-first: the Library never waits for the network; a stale marker; polite rate limits), maps the hub's game id to the RA game id by the same ROM hash, and shows completion on game cards ("12 / 40", a ring), a "Retro achievements" tab on the profile page next to the native ones (one list, an icon says which kind), and "this game has achievements" on the game page.
5. **The unlock moment:** when an emulator unlocks, the player sees the same console toast as a native unlock (T-246 kind "achievement": name, badge image, points, "RetroAchievements" credit), respecting quiet mode and "don't interrupt games". The emulator may draw its own toast too: the hub's `Report` carries an optional `achievement_unlocked` event so the console can show its own and offer to switch the emulator's off; without it, the console polls the recent unlocks only while a game from a supported system runs (long interval, battery of the network, easy to turn off).

## Use cases
1. Player links the account once, plays Sonic on RetroArch, unlocks "First Ring": the toast shows, the Library card shows 1/38.
2. Two profiles, two accounts; a child profile has none.
3. The ROM on the USB drive is a different dump than the set expects: the game page says "No achievements for this version" (hash not matched) instead of nothing.
4. Offline: unlocks queue in the emulator (its own behaviour); the Library shows the last cached numbers with an "as of" time.
5. Hardcore: the Guide menu's save-state and rewind entries (if the OS ever offers them, T-273/T-305) warn that they end a hardcore run.

## Children
T-315 spike and contract (lead): ToS/rate-limit read, token handling, supported systems and hash rules, `ra` service and `Hub1` additions · T-316 account link UI and credential hand-over (RetroArch recipe) · T-317 RA data in the shell: cache service, Library rings, profile tab, game page · T-318 unlock moment and presence: toast through the notification bridge, `Report` event, polling fallback, now-playing "rich presence" line.

## Open owner decisions (also in STATUS)
(a) May the console talk to retroachievements.org for the player at all (a third party; its terms; the **ROM hash sent to the site reveals what is played**: privacy and telemetry stance, ADR-021)? (b) May we use the RetroAchievements name and badge images in the UI (trademark/permission: ask the site operators before shipping; the task builds with neutral text and the site's own images fetched at run time, cached per profile, never bundled)? (c) Token storage and whether it is backed up with the profile. (d) Child profiles: off by default (recommended). (e) `rcheevos` and any bundling: licence check by the spike, no code taken before it. No ROM, set or image is ever shipped by us.

## Scope of this task (docs only)
Write 03 "Retro achievements" (service, data flow, token handling, permissions, offline behaviour) and the 02 notes (profile tab, game page, toast), consistent with ADR-021, T-246 and T-302; every child traces to a paragraph. Keep the facts above marked unverified until the spike.

## Acceptance criteria
- [ ] The spec sections exist and agree with ADR-021, T-246, T-302 and the children; `.\scripts\dev.ps1 docs` green.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
