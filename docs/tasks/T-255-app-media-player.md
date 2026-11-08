# T-255 — First-party app: Media player (local files)

Status: todo · Phase: 7 · Depends: T-251, T-252, T-256 · Area: apps · Size: M · Owner: builder · Developer surface: none

## Goal
Play video and music from the console's storage and USB drives with a controller: a library view per folder, a playback screen with the usual controls, subtitles and audio tracks, resume where you stopped. Part of T-248; its own Flatpak (`org.ruyaos.Player`); streaming and network libraries are T-257 and later.

## Read first
- T-248, `docs/specs/06-hig.md`, the app template (T-252), `docs/developers/audio-and-video.md`, ADR-009 and the codec policy in `docs/specs/01-platform.md` and `03` §6 (what the image ships: hardware decode through VA-API, which codecs are free, what needs `ffmpeg-full` or a Flatpak extension), T-219 (audio formats and passthrough, if built), T-202 (inhibit sleep while playing), the file manager's browsing code (T-256: share, do not duplicate)

## Scope
1. **Codec situation, recorded first** (in the Outcome and `docs/developers/audio-and-video.md`): which containers and codecs play out of the box on the image and on the Flatpak runtime (H.264, HEVC, AV1, VP9; AAC, MP3, FLAC, Opus; AC-3/E-AC-3/DTS), which do not and why (patents, packages), and what the user sees for an unsupported file (a plain message, not a black screen). Any licensing question is owner-level: write it down, do not decide.
2. **Engine:** Qt Multimedia (FFmpeg backend) unless the audit finds it insufficient, with hardware decode when available and a software fallback; one playing item at a time.
3. **Screens:** folder browser (shared with T-256's component), a playback screen (play, pause, seek by stick or triggers with a time preview, volume through the system, audio and subtitle track menus, aspect, speed), a music mode (queue, album art, shuffle, repeat), "continue watching" per profile (position stored in the app's data), subtitles (SRT and embedded text; style tokens, size setting).
4. **System behaviour:** inhibits the screen saver and sleep while video plays (T-202), pauses when the Guide overlay opens or the profile is locked, reports play time to the platform (T-247's ledger counts it as the foreground app; nothing extra), notifications for errors only.
5. Turkish and English, accessible names, themes, reduced motion.

## Out of scope
- Streaming services, DRM, DVD and Blu-ray (libdvdcss is an owner decision), network shares (T-257, later), transcoding.

## Acceptance criteria
- [ ] Tests with fake media backends: the browser and focus, transport controls and seek limits, track menus, resume position store and its atomicity, the unsupported-file path, pause on Guide, inhibit requested and released, controller-only operation.
- [ ] The codec table in the Outcome is verified by playing sample files in the VM (lead run: H.264 and one audio format at least; hardware decode noted when available).
- [ ] Screenshots (English and Turkish) against `04` §8 and the HIG checklist.
- [ ] Builds as a Flatpak from the template; `.\scripts\dev.ps1 test` green.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): none. Dogfooding rule: this app may use only the public surface; if it needs something else, add an Inbox line proposing the capability, do not use a private service.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
