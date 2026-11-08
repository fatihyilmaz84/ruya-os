# T-249 — Human Interface Guidelines for app authors (`docs/specs/06-hig.md`)

Status: todo · Phase: 7 · Depends: — · Area: docs · Size: M · Owner: lead · Developer surface: none

## Goal
One document that tells the author of an app (first-party or third-party) how an app must look and behave on RuyaOS: the rules the shell already follows, written for people who do not read our source. Part of the first-party apps epic (T-248). It reuses spec 04 rather than copying it, and is linked from the developer guide (T-214).

## Read first
- `docs/specs/04-design-system.md` (tokens, components, focus, motion, §7 accessibility, §8), `02-shell.md` (input, navigation, the Guide overlay, the hint bar), `03-services-and-apps.md` §4.5a (saves), `docs/developers/` (`controller-input.md`, `fullscreen-and-lifecycle.md`, `saves-and-data.md`, `audio-and-video.md`), `shell/CLAUDE.md` and `shell/PATTERNS.md` (the rules in practice)

## Scope
`docs/specs/06-hig.md`, one section each, with short do and don't examples (small described or ASCII layouts; no images needed):
1. **Principles** (controller first, 10-foot reading, calm and glassy, never lose focus) and what an app owns versus the shell (the Guide overlay, the volume OSD, notifications, power).
2. **Focus and navigation:** one focus at all times, it moves in the direction pressed, wrap rules, the ring is never hidden, focus is remembered when you come back, no hover-only UI, no mouse requirement; lists, grids, tabs, dialogs, side panels.
3. **Buttons:** A/B/X/Y, LB/RB, triggers, menu, Guide (the shell's, never an app's), back; what each does by default; long press; auto-repeat; the on-screen keyboard and when it opens; keyboard and mouse as secondary.
4. **Sizes and layout:** the 10-foot type scale, minimum focus-target size, safe areas and overscan, margins, density at 720p, 1080p and 4K, the colour themes (T-209).
5. **Look:** use the tokens and components (links to 04, and to the RuyaKit names once T-251 exists), glass and shadows and when to avoid them, motion and reduced motion, colour never the only cue, art rules (hero, logo, tile), the icon set (Material Symbols Rounded).
6. **Sound and feedback:** UI sounds (T-227), no autoplaying audio, volume belongs to the system, rumble.
7. **Text input:** the on-screen keyboard, passwords, search; avoid typing where you can.
8. **Lifecycle:** what an app does on suspend, Stop, a profile switch and a crash (save early and often, atomic writes, `saves-and-data.md`), a launch-time budget, splash, error and offline states in plain words.
9. **Accessibility:** names and roles, contrast numbers (04 §7), text scaling, screen reader hooks, reduced motion, subtitles for video.
10. **Content and copy:** plain words, no jargon, sentence case, numbers and dates by locale, translations without concatenated strings, errors that say what to do.
11. **A checklist** an author runs before publishing (a table of testable items; the template of T-252 links it).

## Out of scope
- The RuyaKit API reference (T-251), the `.play` format (spec 05), a visual style board (the owner's canvas).

## Acceptance criteria
- [ ] The document covers all eleven sections; every rule says which part of the shell or of spec 04 it comes from. A rule that the shell itself breaks is listed as an Inbox line, not invented away.
- [ ] Linked from `docs/developers/README.md`, `00-overview.md` and spec 04; `lint-dev-docs.ps1` passes where its format applies.
- [ ] A reviewer who has not read the shell code can follow the checklist on one existing shell screen and find it passing.

## Outcome
_Filled in by the implementer. First line: `Verified: host | unverified`. Then: what was written, files, deviations._
