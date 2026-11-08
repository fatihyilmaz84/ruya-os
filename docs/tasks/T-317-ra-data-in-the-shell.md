# T-317 — RetroAchievements data in the shell: cached progress, Library rings, profile tab, game page

Status: todo · Phase: 5 · Depends: T-316, T-307, T-246 · Area: services, shell · Size: M · Owner: builder · Developer surface: none

## Goal
Completion and recent unlocks of the linked account show where the player looks: a ring or "12 / 40" on retro game cards, a "Retro" tab beside the native achievements on the profile page, and the achievement list on the game page, always instantly (cached) and honest about being stale. Part of epic T-314.

## Read first
- T-314, T-315, T-316, T-246 (native model and pages: one list, an icon for the kind), T-307 (game identity in the Library), `shell/src/network` (pane pattern), 04 §5/§7/§8

## Scope
1. **Cache in the service:** per profile and game, progress and achievement list (names, descriptions, badge image URLs, points, unlocked time), refreshed on link, on game start/stop, and by a slow timer while online; offline-first, stale marker with the "as of" time; badge images fetched at run time into a per-profile cache with size limits and decoding checks, never bundled; ROM hash -> RA game id by the hub's game id (T-315).
2. **Library:** completion ring or "12 / 40" on cards of games with a set (no layout change for others; card sizes stay standard), "No achievements for this version" on the game page when the hash is not matched.
3. **Profile page:** a Retro tab (score, games by completion), the list per game with hidden/unearned styling as in T-246; native and retro in one page with an icon per kind.
4. States: not linked (a short invitation), loading, empty, offline/stale, failed, rate-limited. Turkish strings, existing components only, late-reply guards, focus asserted, Back leaves every state.

## Out of scope
- The unlock toast (T-318), leaderboards, friends, comments, mastery badges beyond a completed state.

## Acceptance criteria
- [ ] Rust tests: cache refresh and staleness, rate limiting, image caps, hash mapping with fixtures, privacy between profiles.
- [ ] `tst_retro_achievements_view.qml` (mock): ring/number, version mismatch text, every state, focus, Back, late replies; screenshots (English, Turkish; Dreamglass and Daylight) read against 04 §7/§8; UX notes line.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
