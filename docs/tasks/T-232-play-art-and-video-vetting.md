# T-232 — Art and video vetting: decode, check, re-encode (pure core)

Status: todo · Phase: 7 · Depends: T-230 · Area: services · Size: M · Owner: builder

## Goal
Given the art files of a package, produce the canonical, vetted set the shell will load (05 §5, §12), or a precise list of problems. The shell never opens a raw file from a package.

## Read first
- `docs/specs/05-play-packages.md` §5 (slots, sizes, formats), §12 (canonical outputs), §9.1 (decoder risk)
- T-230 (reader and error type); `docs/specs/04-design-system.md` §5 (Art card 16:9, Cover card 2:3, hero composition)

## Scope
1. A module/crate for slot validation: per slot (`icon`, `logo`, `hero`, `cover`, `screenshots[]`, `trailer.poster`) check format by **magic bytes** (not extension), dimensions and aspect ratio before decoding pixels (read the header only, refuse oversized dimensions: at most 8192x8192 and 64 megapixels, so a tiny file cannot expand to gigabytes), file size, no animation, no SVG.
2. Decode with a memory-safe Rust image library (choose one with a permissive licence; record it; `cargo deny` clean), convert to sRGB, strip metadata, re-encode to WebP at the canonical sizes (05 §12; never upscale), deterministic output.
3. Video (`trailer`, `preview`): **container and codec allow-list check only** (WebM VP9/AV1+Opus, MP4 H.264+AAC; preview with no audio), duration, resolution, bitrate and size limits read from the headers by a memory-safe parser; no decoding in this task and no re-encode. Anything else is refused. Document the residual risk (Q5).
4. Output: a result per slot (`ok` with the written canonical files, `missing`, `invalid` with a code). Missing optional art is not an error; a malformed `icon` or `hero` is.
5. A tile generator input: dominant colour of the hero for the shell's tint when only some art exists (pure function, tested) if the shell does not already derive it (check `AppArt.qml` first).
6. Runs in the unpack helper's limits (T-237): memory-bounded, no file access except input and output directories, passed as arguments.

## Out of scope
- Playing video, the shell's use of the files (T-242), art for the Store remote metadata.

## Acceptance criteria
- [ ] Fixtures generated in tests (not binary blobs): good image per slot; wrong aspect; too small; too large dimensions ("decompression bomb" header); extension lies (`.png` that is a GIF); animated WebP; SVG named `.png`; truncated file; non-sRGB profile (converted); EXIF with GPS (removed from the output, test reads the output bytes); each gets its own error code or outcome (`tests/art.rs`).
- [ ] Output is deterministic: two runs give identical bytes (`tests/art.rs::deterministic`).
- [ ] Video allow-list: accepted and refused fixtures for each codec/container, an over-long and an over-large one, a preview with an audio track (`tests/video.rs`).
- [ ] Peak memory for the largest allowed image stays under a stated bound (measured once, bound asserted by dimension arithmetic in a unit test).
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- Spec 05 §5 and §12 with the libraries and limits as built.

## Hints
- Reading headers first is the whole defence against bombs: test it by giving the decoder a file it must never be asked to decode.

## Outcome
_Filled in by the implementer._
