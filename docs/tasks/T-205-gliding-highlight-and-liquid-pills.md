# T-205 — Gliding highlight with velocity stretch, and liquid-glass pills

Status: in-progress · Phase: 2 · Depends: T-204 · Area: shell · Size: M · Owner: builder

## Goal
Moving through the section nav and the Settings categories feels like one highlight gliding between rows (and stretching when you scroll fast) instead of each row switching its fill; on capable GPUs the top-bar pills refract what is behind them. Both from `04` §3.8 (owner, 2026-11-06). Riskier than T-204 (a different focus architecture, a shader), hence the lead.

## Read first
- `docs/specs/04-design-system.md` §3.8 (gliding highlight, liquid pill), §4 focus (the ring never fades during a move; focus is never shown by colour alone), `02-shell.md` (section nav, Settings, accessibility of focus)
- T-204's Outcome (tokens `easeGlide`, `motionScale`, shadows, `GlassLayers`), `GlassPill.qml`, `SectionNav`, `SettingsPage.qml`, `PATTERNS.md` focus rules, the accessibility tests (focus + role assertions)
- B-002/B-003 in `STATUS.md` (real-GPU measurements)

## Scope
1. **Highlight component** (`FocusGlide.qml`): follows the focused item's geometry in a list/row of siblings, glides with `easeGlide` over 280 ms x `motionScale`, retargets from its current position (no jump, no restart from zero) and snaps when `motionScale` is 0. Focus itself stays on the real items (keys, accessibility, hit areas unchanged); the highlight is a visual that never takes focus and never lags behind the item the screen reader announces. Stretch: length factor from velocity (|dx|/dt / 2600 units per s, clamped 0..1, smoothed at 14 per s), off under reduced motion.
2. **Use it** in the section nav (Home/Games/Store/... pills) and the Settings category list; the rows keep their own focus ring/fill as the fallback when the highlight cannot be shown (Performance tier may keep the plain fill). The ring "never fades during a move" rule holds: the highlight is under the ring, the ring is on the item.
3. **Liquid pill (High tier only):** a small `ShaderEffect` per top-bar pill over its blurred crop: edge refraction (bend min(0.5 x h, 30)), a slow moving specular (three sines, 9/15/23 s), computed on one texture per pill; `qsb` shaders built through the shell's CMake (check Qt 6.8 on Fedora and 6.10 here); any failure to compile falls back to the plain pill. Gate by tier and by a measured budget; decide on the Dell whether High keeps it by default.
4. **Docs/spec:** mark the §3.8 rows built or rejected with the measurement; screenshots.

## Out of scope
- Grid card focus (stays per-card), glass over a running app (B-003), refraction on large panels.

## Acceptance criteria
- [ ] Tests: the highlight's geometry follows focus changes (assert its target `x/y/width/height` equals the focused item's), retargets mid-glide without a jump (sample the property across a fake clock), snaps with `motionScale` 0, never holds focus (`activeFocus` false), and the accessibility tests (focused item has name and role) still pass; stretch factor from a scripted velocity.
- [ ] Screenshots: nav mid-glide, at rest, fast stretch (if a screenshot can catch it), liquid pill on High vs plain on Balanced; read against `04` §8.
- [ ] Hardware (the Dell): frame times with the glide and with liquid pills while moving through the nav ten times; the numbers decide the High default; Outcome records them.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Docs to update
- `04` §3.8 (mark built/rejected), `02-shell.md` if navigation behaviour is described, `shell/CLAUDE.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
