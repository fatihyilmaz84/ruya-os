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
Verified: hw (Dell 0.0.61 with this branch's shell binary run from `/var/tmp` by a runtime drop-in; no image built)
UX notes: states reached on the Dell and in `shots`: Home, Settings (My profile, Display & motion), the wallpaper picker fresh and after SuperTuxKart was in front, the default look and Dusk/Aurora. Nothing about focus or Back changed: Back from the category list still lands on the section nav (asserted in the new tests); the picker still takes the grid's focus. Doubt: the blobs now rest 30 s after the last input (see Deviations); the owner may want them moving.

Builder: Opus 5.5, effort high, round 1.

**Reproduced on the Dell first (0.0.61, the owner's settings: Midnight, the default look, High).** KMS captures (`ffmpeg -f kmsgrab` through VA-API) and a property dump of every effect item, taken by a scratch probe (the real `Compositor` loaded with `ruya-shell --load`, plus a timer that prints the tree and a command file), then the same flow again with the unmodified shell after a reboot:
- The scene graph is OpenGL on the GPU (`GraphicsInfo.api` 3, GL 3.2, `effectsQuality` high, `blurMax` 64, no tier or degrade rule switches blur off at run time: there is none). Every blur item is on: both glass pills draw the liquid path (`liquid` true, `compiled` true, the masked `MultiEffect` `blurEnabled`, `blurMax` 25.6), the picker's `GlassSheet` is `blurred`, `engaged`, its mask handed over (`maskSource` = `glassSheetMask`), `blurMax` 64; with a wallpaper the page blur (`wallpaperBlur`) is drawn.
- The captures agree: with a blob held across the nav pill its edge is soft inside the pill and sharp outside; the picker sheet shows a soft blob, fresh and after STK was in front (real shell after a reboot, `real-picker-fresh`/`real-after-picker`), with the default look and with Dusk; a DPMS off/on cycle changes nothing. So the T-387 fix reaches the Dell and the glass components render on its GPU as on the host.
- **What reads as "glass without blur": the default look on pages.** L0 was blurred on pages only for a wallpaper picture (`WallpaperLayer` blurs `pictures`; with no wallpaper `wallpaperBlurLoader` is inactive): the blobs stayed sharp, and the Settings rows (translucent `glass`, which blur nothing themselves) showed the blobs' hard edges straight through (capture `real-settings-1`: the largest step between neighbouring pixels in the left margin, where only L0 is drawn, was 16 to 19 levels whenever an edge crossed it; 2 over the blurred Aurora page). That breaks 04 §3.6 ("never translucent glass over sharp art") on the owner's setting. The glass sheet and pills blur a crop of the same dark, low-contrast Midnight blobs, so their blur is real but barely visible; the Home hero (no art: a colour field) gives the pills nothing to blur.
- **GPU at Home: the blob drift.** The real shell at Home drew 60 frames a second forever (probe: 300 frames per 5 s) at 29 to 32 % render time (one drm client id; the lead's 40 % was a busier moment). Pausing the drift by hand: 0 ms and 0 frames. The blobs drifted under the hero's opaque colour field, where nobody sees them, and every frame redrew the whole scene: L0 about 12 %, the two pills (live crop, blur, liquid shader, shadow per frame) about 11 %, the rest about 6 %.

**Built:**
- `Backdrop.qml`: the gradient and blobs are one item (`backdropFields`); on a page (`blurred`, set by Shell from `pageOpen`) a quarter-size live `ShaderEffectSource` of it is blurred by one `MultiEffect` (`backdropBlur`, `blurMax` per tier) that fades in over `pageMs`, exactly as `WallpaperLayer` does for a picture; not on Performance; its Loader exists only while the backdrop is shown, so with a wallpaper the picture's blur is the only one. Once the copy covers, `hideSource` stops drawing the sharp fields under it (measured 8 % on the Dell while they drift).
- `Shell.qml`: `backdrop.paused` is also true while the Home hero covers it (`heroArt.covers`: settled on Home with no wallpaper, so an art layer's fill is opaque) and while `LiquidGate` is not running (30 s without input, as the liquid pill's specular); `backdrop.blurred: root.pageOpen`.
- `scripts/dell-glass-check.sh` (new, exec bit): Home still for 40 s, render time over 10 s, PASS under 3 %; Settings, six captures, the largest neighbour step in the left margin, PASS under 6; the Settings idle number; captures copied for review. `docs/dev-setup.md` names it.
- Specs: 04 §3.5 L0 row, §3.6 (pages blur L0 whatever it shows; the Dell finding), the Backdrop component row; 02 tiers paragraph (where the drift rests).

**hw, after (this branch on the Dell, same flow):** KMS captures of Home, Settings and the picker after SuperTuxKart was in front and quit: the Settings rows lie over softly blurred blobs, the picker sheet shows the blurred backdrop, the pills as before (`fin-after-*.png`, `check-final/`; the 0.0.61 ones are `real-*.png`, `check-before/`; all in this worktree's `output/t421/`, not in git). `scripts/dell-glass-check.sh`: 0.0.61 FAIL twice (Home still 3251 ms in 10 s; a margin step of 16 on Settings), this branch PASS (Home still 0 ms; largest step 2 over six captures).

**GPU (render time of the shell over 10 s, `drm-engine-render`, one client id; 1080p, Midnight, default look):**

| Moment | 0.0.61 | this branch | What draws |
|---|---|---|---|
| Home, more than 40 s without input | 2958 to 3251 ms (30 to 32 %) | 0 ms | 0.0.61: the drift under the hero, 60 full frames a second; now nothing |
| Home, input in the last 30 s | 3091 ms (30 %) | 2564 ms (25 %) | the liquid pills' clock (by design for 30 s, LiquidGate), each pill's live crop, blur and shader per frame |
| Settings, more than 40 s without input | 2986 to 3061 ms (30 %) | 8 ms | 0.0.61: the drift; now it rests |
| Settings, input in the last 30 s | about 30 % | 4036 ms (40 %) | the drift, the new page blur (about 12 %, 8 % saved by `hideSource`) and the pills |

So the lead's "40 % at Home" was the blob drift under an opaque hero (plus the pills redrawing for it); fixed. Active use of a page costs more than before because the page is now blurred as 04 §3.6 asks; an idle screen costs nothing.

**Dell (what was done):** signed in as p1 with a throw-away uinput keyboard (scratch `keys.py`); KMS captures with ffmpeg; a scratch probe and this branch's `ruya-shell` ran from `/var/tmp/t421` through drop-ins (`/etc/...ruya-compositor@tty1.service.d/t421.conf` for one reboot, then a runtime one in `/run`); two reboots; wallpaper set to Aurora and Dusk for tests and back to the default (as the owner had it); SuperTuxKart launched and stopped four times, ACBR once (it never showed a window); two running ACBR scopes (one older than this session) and the STK scopes stopped through `systemctl --user -M ruya-p1@ stop`; IdleClock saver/off cycled once (DPMS). At the end: drop-ins and `/var/tmp/t421` removed, the 0.0.61 `ruya-shell` running, `shell.conf` as found (Midnight, no wallpaper), p1 signed in. In WSL: the `shell-build` stage built twice from this worktree (no image), its image removed, `free-space.ps1 -KeepWork` run.

**Deviations:**
- The drift now rests 30 s after the last input (`LiquidGate`) also where it is seen (the profile picker, pages). Not asked for in words; done because on a still page the blobs plus the new page blur kept the Dell's GPU at about 47 % (39 % with `hideSource`), and shell/CLAUDE.md says nothing decorative animates forever on a still screen. The next key resumes it from where it stopped. One line to revert in `Shell.qml` if the owner wants the blobs moving on an idle screen.
- No image was built: the hw criterion was checked with this branch's `ruya-shell` built from `image/Containerfile`'s `shell-build` stage in WSL (Qt 6.11.2, the Dell's) and run from `/var/tmp` by a runtime drop-in; the drop-in was removed and the Dell runs the 0.0.61 shell again.

**Tests and revert checks (`revert-check.ps1`, and by hand for the `shots` case):**
- `tst_wallpaper test_the_default_look_is_blurred_on_pages` (Home: copy ready, not drawn, fields drawn; Settings: `backdropBlur` blur 1, `blurMax` 64/32, drawn, made from `backdropFields`, the fields hidden under it, no `wallpaperBlur`; Performance: no item; a wallpaper: the backdrop's blur goes, the picture's is drawn; Back lands on the section nav): red with the Loader `active: false`, red with `hideSource: false`.
- `tst_shell test_backdrop_rests_under_the_home_hero` (drifts on the picker, rests under the settled hero, drifts on Settings, rests again on Home): red without `|| heroArt.covers`.
- `tst_shell test_backdrop_rests_when_idle_and_drifts_on_input` (`LiquidGate.idleMs` 150: rests, a key resumes it, focus stays in the category list): red without `|| !LiquidGate.running`.
- `shots` `tst_wallpaper test_zz_default_look_page_is_blurred` (GPU: the blobs held still with the first blob's edge across the left margin; along that row the largest neighbour step must be under 6): passes with the fix; 28 with the Loader `active: false` (the old look; the test waits on `backdrop.blurred`, not on the blur item, so the pixels decide). An earlier variant that waited on the blur item was 27 with the blur hidden, before `hideSource` existed.
- Files: `shell/qml/Backdrop.qml`, `shell/qml/Shell.qml`, `shell/tests/tst_wallpaper.qml`, `shell/tests/tst_shell.qml`, `shell/tests/tst_motion.qml`, `scripts/dell-glass-check.sh`, `docs/specs/04-design-system.md`, `docs/specs/02-shell.md`, `docs/dev-setup.md`.
- Unverified: KMS captures are the framebuffer, not what the TV shows (its RGB range and picture mode were not checked); the owner has not looked at this branch on the TV. The check script ran against this branch's binary and 0.0.61 only, not against an image.
- Changed premises: four checks asserted "the blobs drift on Home" (`tst_motion` `test_defaults`, `test_reduced_motion`, `test_quality_tiers`; `tst_shell test_backdrop_stops_while_app_focused`); on Home they now rest by design, so they check the drift on Settings, where the blobs are seen, with the same assertions (drift by default, stops under reduced motion and Performance, resumes, stops behind an app). `test_reduced_motion` also checks that navigation works under reduced motion as before. Not weakened: every former assertion is still made, on the screen where it is visible.
