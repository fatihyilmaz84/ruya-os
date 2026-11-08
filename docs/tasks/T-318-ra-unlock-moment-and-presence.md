# T-318 — Retro unlock moment and presence: the console toast for emulator unlocks, the report event, the polling fallback

Status: todo · Phase: 5 · Depends: T-317, T-246, T-245, T-306 · Area: services, shell · Size: M · Owner: lead · Developer surface: internal

## Goal
When an emulator unlocks a RetroAchievement, the console shows its own "Achievement unlocked" moment (the T-246 toast: name, badge, points, the RetroAchievements credit), kept in the notification centre, without a second toast war with the emulator, and the Library's "now playing" line can show the game's rich-presence text. Part of epic T-314.

## Read first
- T-314, T-315, T-317, T-246 (toast kind and quiet mode), T-245 (bridge), T-306 (now-playing `Report`), T-227 (cue), T-273..T-279 if built (a frozen game must not poll)

## Scope
1. **Report event:** `Hub1.Report` gets an optional `achievement_unlocked{id, title, points, badge}` (emulators that integrate send it); the service verifies it against the cached set (unknown ids are dropped) and raises the notification kind "achievement" with the retro credit.
2. **Fallback:** for a supported-system game with a linked account and no reporting emulator, poll the recent unlocks on a long interval while the game runs (backoff, off when the game is frozen or the network is down, a Settings switch "Show unlocks from emulators"); a missed poll only delays the toast, never loses the unlock.
3. **Duplicate toasts:** a switch in the hand-over (T-316) asks RetroArch to hide its own notification (config key per T-315) when the console shows its own; documented, off when the user prefers the emulator's.
4. **Presence:** the site's rich-presence string, when available, is shown as the second line of "now playing" (T-306) and sent to nobody else; off in quiet mode and for profiles that disabled presence.
5. Quiet mode and "don't interrupt games" behave as in T-246 (a small corner toast while a game runs); the sound cue from T-227.

## Out of scope
- Unlock sharing, friends, a stream overlay, hardcore enforcement.

## Acceptance criteria
- [ ] Rust tests: event verification (unknown id, repeated unlock, wrong profile), polling backoff and stop conditions, presence off switch.
- [ ] QML tests (mock): toast in normal and game-running modes, quiet mode, no duplicate for the same unlock, centre entry; screenshots; UX notes line.
- [ ] VM (lead run): the fake site from T-316's check unlocks while a sample app runs: toast event and centre entry seen. Dell/hw: a real RetroArch with a real account (unverified until then).
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …, hw pending: …)`._
