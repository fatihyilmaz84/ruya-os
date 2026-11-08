# T-254 — First-party app: Weather

Status: todo · Phase: 7 · Depends: T-251, T-252 · Area: apps · Size: M · Owner: builder · Developer surface: none

## Goal
A glanceable weather app for the living room: the current conditions and the next days for a few saved places, in the Dreamglass look, with no account and no tracking. Part of T-248; its own Flatpak (`org.ruyaos.Weather`).

## Read first
- T-248, `docs/specs/06-hig.md`, the app template (T-252), T-213 (time zone and locale), `docs/specs/03-services-and-apps.md` (network state API, the permission to reach the internet), `docs/developers/permissions-and-sandbox.md`

## Scope
1. **Data source decision (recorded in the Outcome; a keyless open API such as Open-Meteo is the candidate, check its terms for non-commercial and attribution requirements before choosing; a paid or keyed service or a terms problem is an owner-level call: stop and ask):** requests only to the one host, HTTPS, no user identifier, a short cache, a plain "offline" state with the last data and its age.
2. **Places:** search by name (on-screen keyboard), the geocoding answer shown as "City, Region, Country", up to six saved places per profile, a default; no location from the network or the GPS without a later, explicit permission task.
3. **Screens:** current conditions (temperature, feel, wind, humidity, a drawn icon set of our own, no third-party art), the next 24 hours and 7 days, units (metric or imperial, from the locale), sunrise and sunset; a hero background that follows the weather and respects the themes and the quality tiers.
4. Turkish and English, locale numbers and dates, accessible names, reduced motion.

## Out of scope
- Maps and radar, alerts and push, widgets on Home (a later task for Home integration), automatic location.

## Acceptance criteria
- [ ] Tests with a fake server: parsing (including missing fields and unit conversion), the cache and the offline state, place search and the saved list, forecast screens and focus, controller-only operation; a malformed answer never crashes.
- [ ] The source's terms and attribution are recorded and shown in an About line; the icon art is our own (CC0) and listed in the licences.
- [ ] Screenshots (English and Turkish) against `04` §8 and the HIG checklist.
- [ ] Builds as a Flatpak from the template; VM (lead run): it fetches a real forecast through the guest's network.
- [ ] `.\scripts\dev.ps1 test` green.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): none. Dogfooding rule: this app may use only the public surface; if it needs something else, add an Inbox line proposing the capability, do not use a private service.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
