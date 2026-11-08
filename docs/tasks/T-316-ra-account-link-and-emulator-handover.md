# T-316 — RetroAchievements account link in Settings and the credential hand-over to emulators

Status: todo · Phase: 5 · Depends: T-315, T-304, T-220, T-211 · Area: services, shell · Size: M · Owner: builder · Developer surface: public-API

## Goal
A player links a RetroAchievements account to their profile from the couch (no password typed more than once), and an emulator that is allowed to gets logged in at start without the player touching the emulator's own menus. Part of epic T-314.

## Read first
- T-314, T-315 (contract, research), T-304 (`Hub1`), T-220 (per-app permissions), T-211 (child profiles), `ruya-profiles` (reference service, secrets handling), `shell/src/profiles` (PIN flows), `shell/PATTERNS.md` (text input, settings rows), 04 §5/§8

## Scope
1. **Service `ruya-retroachievements`** (Rust, pure core with a fake HTTP trait + store, like `ruya-profiles`): `Link`/`LinkToken`/`Unlink`/`GetAccount` from the T-315 contract; the token in a root-only 0600 file per profile (atomic write), never logged, deleted with the profile; polite client (user agent, backoff, rate limits per T-315); hardened unit, restrictive bus policy.
2. **Settings** Profiles > you > Achievements > Retro: states Not linked / Linking / Linked as <name> / Error (bad credentials, offline, rate-limited); link with the existing text-input flow, or the QR route; Unlink with confirmation; off and explained for child profiles; mock and D-Bus client agree with the XML.
3. **Hand-over:** `Hub1` gives an opted-in app the username and token for the calling profile (the uid decides); permission row "RetroAchievements account" in T-220's list; the first-party frontend (T-259) and the RetroArch recipe write `cheevos_*` keys in the profile's RetroArch config at launch, and remove them on unlink.

## Out of scope
- Showing data (T-317), the unlock moment (T-318), creating accounts, hardcore-mode policy beyond passing the player's choice.

## Acceptance criteria
- [ ] Rust tests: link/unlink with a fake site (good, bad credentials, offline, rate limit), token never in logs or errors, file modes, profile deletion, hand-over only to the permitted app of the calling profile, privacy between profiles.
- [ ] `tst_retro_achievements_link.qml` (mock): every state, focus after each step, Back leaves each, child profile blocked, late replies dropped; screenshots (English, Turkish).
- [ ] XML, mock, client and service agree. VM (lead run): `scripts/vm-retroachievements-check.sh` with a local fake site: link, hand-over, unlink, `systemd-analyze security`.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): what an emulator is handed (a token, not a password) is a contract developers rely on: document it in the emulator-author paragraph (T-308 chapter), with a sample and a conformance test of the hand-over, per-app permission and revocation.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …)`._
