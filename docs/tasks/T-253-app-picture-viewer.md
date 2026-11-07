# T-253 — First-party app: Picture viewer

Status: todo · Phase: 7 · Depends: T-251, T-252 · Area: samples, apps · Size: M · Owner: builder

## Goal
The smallest real app, and the proof that the template, RuyaKit and the HIG work together: browse pictures from the console's storage and USB drives, view them full screen with controller zoom and pan, and run a slideshow. Part of T-248; distributed as its own Flatpak (`org.ruyaos.Pictures`), never in the image.

## Read first
- T-248, `docs/specs/06-hig.md`, the app template (T-252), `docs/specs/03-services-and-apps.md` (media access: mounts belong to `ruya-shell`, apps get files through the portal or a permitted path), Storage service interface, `docs/developers/audio-and-video.md`

## Scope
1. A grid of folders and pictures (thumbnails decoded asynchronously and cached; one level of folder navigation; sorted by name or date), a viewer (fit, zoom with the triggers, pan with the stick, rotate, next and previous with LB/RB, a hint bar), a slideshow (interval choice, shuffle, a calm cross-fade, stops on any key), EXIF date and size in an info panel.
2. Formats: JPEG, PNG, WebP, GIF (first frame; animated is optional), HEIC only if the image has the plugin (record). **Hostile files:** size and pixel caps before decoding (a 40-megapixel limit), a decode failure shows a placeholder and goes on; nothing on a drive is executed or auto-opened; file names shown as plain text.
3. Access: pictures through the file chooser portal or the permitted media paths (state what the sandbox grants: `--filesystem` is not asked for broadly); remembers the last folder per profile in its own data directory.
4. Turkish, accessible names, reduced motion, themes, quality tiers.

## Out of scope
- Editing, cloud albums, face tagging, video (T-255).

## Acceptance criteria
- [ ] Tests (mock file system): the grid and its focus, folder navigation and back, viewer zoom and pan limits, slideshow start and stop, hostile-file handling (oversize, corrupt, symlink escape), controller-only operation, focus asserted after every move.
- [ ] Screenshots (English and Turkish) against `04` §8 and the HIG checklist, passed.
- [ ] Builds as a Flatpak from the template; `appstreamcli validate` passes. VM (lead run): installs through the Store and opens a folder on a mounted USB stick.
- [ ] `.\scripts\dev.ps1 test` green.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
