# T-208 — Wallpapers: choose the picture behind the shell

Status: todo · Phase: 2 · Depends: — · Area: shell, services · Size: M · Owner: builder

## Goal
The owner can pick a wallpaper in Settings. It is the picture behind Home when there is no hero art and, blurred, behind pages and glass (`04` §3.5 layer L0, §3.6). Owner request, 2026-11-06. Today L0 is the hero art or the tinted blobs.

## Read first
- `docs/specs/04-design-system.md` §3.5 (L0 backdrop: "hero art (Home), blurred hero art (pages), tinted blobs when there is no art"), §3.6 (one shared blurred copy, never a second full-screen blur), §1 principles 3 and 5, §3.8 (grain, shadows), §7 accessibility (legibility)
- The backdrop component(s) (`Backdrop*.qml`, the tint/blob code), `DeviceSettings`, `DisplayPane.qml`/Settings panes pattern (`shell/PATTERNS.md`), Storage/Library backends (reading images from USB volumes), `Theme.qml` tints
- The quality tiers (`effectsQuality`): blur levels per tier

## Scope
1. **Sources:** (a) a small bundled set (4 to 6 wallpapers in the Dreamglass look: abstract gradients and soft shapes **made for this project**, licence-clean, 1920x1080, compressed, plus a "Default (animated blobs)" entry that is today's look); (b) pictures from a mounted USB drive (jpg, png, webp; one folder level `Wallpapers/` or `Pictures/`, never executing anything, size-limited, listed by name with a thumbnail); (c) the Store/Games art is not a wallpaper source here.
2. **Setting + storage:** `DeviceSettings.wallpaper` (id or a copied file). A USB pick is **copied** (downscaled to the screen size, max 3840x2160, re-encoded jpg/webp) into the shell's own state directory so removing the stick does not lose it; the copy is done off the GUI thread with a progress/failed state; a size cap and a count cap (say 12 user wallpapers) with a Delete row. Per-profile wallpapers are a later step (profile homes are 0700 and unreadable by the shell: Inbox).
3. **Rendering:** decode asynchronously (`Image { asynchronous: true; sourceSize }` at the screen size), cross-fade on change over `tintMs`; Home shows the wallpaper under a legibility scrim (`heroScrim` rules apply) when there is no hero art and keeps art-led heroes when there is; pages show it through the **one shared blur** (no second full-screen blur); the Performance tier shows the unblurred, darkened wallpaper; a missing or corrupt file falls back to the default look with a log line and a toast "Wallpaper could not be loaded".
4. **Settings UI:** Settings -> Display & motion (or a new "Appearance" pane, decide per `02`/`04`): a Wallpaper row opening a picker grid of thumbnails (controller-first, focus ring, the current one marked), "Add from USB drive..." when a drive with images is mounted, Delete for user wallpapers, "Dim wallpaper" slider (0 to 60 %). `qsTr`, Turkish.
5. **Memory/perf budget:** one decoded wallpaper in memory (plus the one being faded in); thumbnails 320 px; measure shell RSS and frame time on the Dell with a 4K source (Outcome numbers).

## Out of scope
- Video or animated wallpapers, per-profile wallpapers, wallpaper from the web or the Store, automatic colour matching (Inbox: an accent from the wallpaper; compare the study's extraction in `04` §3.8 first), screen savers (T-202).

## Acceptance criteria
- [ ] Tests: choosing a bundled wallpaper sets the setting and the backdrop source; a USB pick copies, downscales and lists it; removing the drive keeps it; Delete removes it; a corrupt file falls back to the default with the toast; the Performance tier uses the unblurred darkened variant (assert the blur property, not pixels); one decoded wallpaper in memory (the old one is released after the fade); the picker is reachable and operable with the controller keys only, focus asserted after every move.
- [ ] Screenshots: Home and a page with a bundled wallpaper and with the default; the picker; a bright wallpaper checked for legibility (contrast numbers for white text over the brightest region with the scrim), read against `04` §8.
- [ ] A bundled wallpaper's source and licence are recorded (own work, CC0 or similar), listed under the licences folder.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN. VM or hardware (lead): the copy from a real stick on the Dell, RSS and frame-time numbers.

## Docs to update
- `04` §3.5/3.6 (the wallpaper in L0), `02-shell.md` (Settings), `LICENSE.md`/licences for the bundled art, `docs/dev-setup.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
