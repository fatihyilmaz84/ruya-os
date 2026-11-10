# T-421 - Glass on the Dell has no Gaussian blur and no transparency (0.0.61), and the shell uses about 40 % of the GPU at Home

Status: in-progress · Phase: 2 · Depends: — · Area: shell (glass: GlassSheet, SectionNav glass, status glass, SmoothMask, Theme effects), image (Qt/Mesa on the Dell) · Size: M · Owner: builder · Complexity: hard · Developer surface: none

## Goal
On the Dell (Intel UHD 630, Mesa, the shell as the compositor) every glass surface looks like 04 §3.6 says: the wallpaper behind it blurred (Gaussian) and tinted, partly transparent, with the sheen and rim. Owner report 2026-11-10 on 0.0.61: "the wallpapers are visible, but there is no gaussian blur/transparency effect". **Dispatch to Opus at high effort** (owner: "send a capable model"); reproduce on the Dell first, then fix.

## What is known (lead-8)
- T-387 (merged in 0.0.61) fixed a real bug on the host GPU (GlassSheet's mask layer toggled under an unchanged `maskSource`; picker tiles' `visible` race; L0 hidden with opacity 0): its `shots` pixel test is red without the fix on Windows. **On the Dell the owner still sees no blur and no transparency**, so either the Dell takes another path (a different cause) or the fix does not reach it.
- The T-387 diagnosis on 0.0.60 (KMS captures with `ffmpeg -f kmsgrab`, a throw-away uinput keyboard: see the T-387 Findings) saw the section nav pill blurred and only the GlassSheet flat; the owner now reports the glass in general.
- `shell.conf` on the Dell: `effectsQuality` High (default), no power saving. Check whether a GPU tier or "degrade" rule (04 principle 5) turns blur off on this GPU at run time, and what the shell logs about RHI, the backend and `MultiEffect` (`QSG_INFO=1`).
- **GPU load:** on 0.0.61, about 2 minutes after boot at Home, the shell's `drm-engine-render` is about 40 % of 10 s (counted once per `drm-client-id`; lead-7's 8.8 % was with STK in front). Find out what draws (a running animation, L0 drawn twice, a layer re-rendered every frame) and whether it is related.

## Read first
- `docs/specs/04-design-system.md` §3.6 (glass), §5 (Glass sheet row), principle 5; `docs/tasks/T-387-*.md` (Findings and Outcome), T-376 (L0 behind an app), T-358 (GPU buffers, the patched Qt dmabuf plugin), T-281/T-204/T-205 (art glow, pills, highlight)
- `shell/qml/GlassSheet.qml`, `SmoothMask.qml`, the section nav and status glass, `Theme.qml` (effects quality, GPU tier), `shell/CLAUDE.md`
- Dell access: CLAUDE.md "The Dell is a pure test machine"; `scripts/dell-update.sh`; stop anything started by hand by its scope

## Scope
1. Reproduce on the Dell with KMS captures at Home, Settings and the wallpaper picker, and a property dump of each glass item (`blurred`, `engaged`, `source`, `maskSource`, the effect's `blurEnabled`/`blurMax`, `Theme` effects state).
2. Find the cause (with evidence: a log line, a property, a bisect against 0.0.59/0.0.60 with `bootc` if useful) and fix it in code, not only on the Dell.
3. Explain the 40 % GPU load and fix it if it is a bug (or file it with numbers).
4. A test that would have caught it: offscreen properties if the cause is logic; a `shots` case if it is rendering; and a Dell check script step (`scripts/vm-display-check.sh` or a new `dell-glass-check.sh` with kmsgrab) for the lead.

## Acceptance criteria
- [ ] The cause named in the Outcome with its evidence; the fix in code; a test red without it.
- [ ] hw (this task, the builder may use the Dell): KMS captures before and after show blurred, tinted, transparent glass at Home, in Settings and in the picker after an app was in front.
- [ ] The GPU load at Home measured before and after (per client id), explained.
- [ ] `dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer._
