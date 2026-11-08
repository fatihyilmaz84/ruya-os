# T-257 — First-party app: Jellyfin client

Status: todo · Phase: 7 · Depends: T-251, T-252, T-255 · Area: apps · Size: M · Owner: builder · Developer surface: none

## Goal
Watch and listen to a Jellyfin server (the owner's own, on the home network) from the couch: sign in, browse libraries, play with direct play first. Part of T-248; its own Flatpak (`org.ruyaos.Jellyfin`). Jellyfin is a separate app from the media player (T-255) and shares its playback component.

## Read first
- T-248, `docs/specs/06-hig.md`, the app template (T-252), the media player (T-255: playback screen, codec table), T-220 (privacy: what an app may reach), `docs/developers/permissions-and-sandbox.md`, the Jellyfin API documentation and its licence terms (the server is GPL-2.0; check that using its public HTTP API and its name in our app is allowed, and write the attribution; any trademark question is owner-level)

## Scope
1. **Sign in:** a server address (typed, or found by the server's local discovery broadcast if the sandbox allows it: record), a user name and a password through the on-screen keyboard, Quick Connect (a code shown on the screen) as the preferred path; the access token is stored in the app's own data directory with mode 0600 per profile and never shown; "Sign out" removes it. The password is never stored. TLS is verified; a self-signed certificate needs an explicit per-server confirmation showing the fingerprint.
2. **Browse:** home with "Continue watching" and "Latest", libraries (movies, shows, music), item pages with art, overview, cast, seasons and episodes, search; artwork loaded lazily and cached; large libraries paged.
3. **Playback:** direct play of what the player can decode (the codec table of T-255); if the server must transcode, ask for a compatible stream profile and say so in plain words; subtitles and audio track choice; reports progress to the server so "continue watching" works on every device; stops reporting when paused for long or on stop.
4. **Offline and errors:** server unreachable, wrong password, token expired, unsupported media, in plain words with a retry; no spinner without a timeout.
5. Turkish and English, accessible names, themes.

## Out of scope
- Remote access over the internet and account services, downloads for offline, live TV and recording, admin functions, other servers (Plex, Emby), DRM.

## Acceptance criteria
- [ ] Tests against a fake Jellyfin server (recorded responses): sign-in paths (password, Quick Connect, bad password, expired token), token storage mode and sign-out, library paging, item page data, playback start and progress reports, the TLS confirmation flow, offline and error states, controller-only operation.
- [ ] A hostile server answer (huge JSON, wrong types, a redirect to another host) is handled without a crash and without leaking the token to another host.
- [ ] Screenshots (English and Turkish) against `04` §8 and the HIG checklist.
- [ ] Builds as a Flatpak from the template; VM or hardware (lead run, needs a Jellyfin server): sign in and direct-play one file. `.\scripts\dev.ps1 test` green.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): none. Dogfooding rule: this app may use only the public surface; if it needs something else, add an Inbox line proposing the capability, do not use a private service.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
