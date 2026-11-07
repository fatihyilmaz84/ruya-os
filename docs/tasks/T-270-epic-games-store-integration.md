# T-270 — Epic Games Store integration (Heroic-style, Legendary backend)

Status: blocked · Phase: 5 · Depends: owner (ADR-018), T-229, T-244, T-251 · Area: docs, services, shell · Size: M · Owner: lead

## Goal
A player signs in to their Epic Games account on the TV, sees their Epic library with art, installs and launches Windows games through the system Wine runner, with cloud saves, like Heroic Games Launcher does on Linux. Owner request, 2026-11-07: "integration with Epic store just like how Heroic does it". Parked until the owner answers ADR-018 (legal and product scope).

## Read first
- `docs/specs/00-overview.md` ADR-018 (Proposed), ADR-014 and `05-play-packages.md` (Wine runner, sandboxed Flatpak apps), ADR-005, §2 scope (Steam and RetroArch are separate Store apps)
- `docs/tasks/T-229-play-feasibility-spike.md`, `T-244-system-wine-runner-pack.md`, `T-248-epic-first-party-apps.md`, `T-251-ruyakit-shared-components.md`
- Upstream: Legendary (GPL-3.0 CLI, the engine Heroic uses for Epic: login, library, install, update, cloud saves, launch args) and Heroic (GPL-3.0)

## Scope (after the owner decision)
1. **Spike (lead):** drive Legendary headless in a sandbox: login by authorization code or device flow (the TV has no keyboard: the code is typed on a phone/PC, or QR/short code), list library, install one free game into the profile's data, launch through the Wine runner with DXVK/VKD3D, cloud-save sync. Record what works on the Dell GPU, the failure modes (anti-cheat titles never work), the download size/time and the disk layout.
2. **Contract + service** (`ruya-store`-style, new `org.ruyaos.Epic1` or inside the apps platform of ADR-015): sign-in state per profile, library list, install/update/uninstall jobs with progress, launch, saves. Credentials stay in the profile's own sealed store, never in the shell, logs or D-Bus replies; nothing runs as root.
3. **First-party app** (controller-first, on RuyaKit): Library grid, game page, install progress, sign-in screen with code/QR, parental age data (T-211) when Epic provides it.
4. Games appear in the unified Library next to Flatpak and `.play` apps.

## Out of scope
- Buying games in the app (open the Epic page on a phone: no payments on the console), Epic Online Services features that need the official launcher, anti-cheat support, GOG/Amazon (the same engine family may follow: separate tasks).

## Acceptance criteria
- [ ] Defined after the spike; each item needs a test or a screenshot. Security: tokens never leave the profile's store; the app runs in a Flatpak sandbox as the profile user.
- [ ] VM (lead run) and Hardware (Dell) checks named by the spike.

## Docs to update
- `03-services-and-apps.md`, the apps epic (T-248), HIG/developer docs, licence notices (GPL-3.0 components bundled or not).

## Outcome
_Filled in by the implementer. First line: `Verified: …`._
