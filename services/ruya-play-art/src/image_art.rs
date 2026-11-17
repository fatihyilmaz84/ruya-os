//! Image slots: header checks first, then decode, sRGB, resize, strip, lossless WebP.

use std::cell::Cell;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use image::codecs::jpeg::JpegDecoder;
use image::codecs::png::PngDecoder;
use image::codecs::webp::{WebPDecoder, WebPEncoder};
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{DynamicImage, ExtendedColorType, ImageDecoder, Limits, RgbaImage};

use crate::{codes, fail, Fail, Slot};

/// Largest accepted width or height (05 section 5).
pub const MAX_DIMENSION: u32 = 8192;
/// Largest accepted pixel count: 64 Mi pixels (8192 x 8192 is exactly this).
pub const MAX_PIXELS: u64 = 64 * 1024 * 1024;

const MIB: u64 = 1024 * 1024;

thread_local! {
    pub(crate) static DECODES: Cell<usize> = const { Cell::new(0) };
}

/// Worst-case heap bytes while vetting one image of `w` x `h`: the decoder's native buffer (8
/// bytes per pixel for 16-bit RGBA) plus the RGBA8 copy (4 bytes per pixel), plus the resampler's
/// intermediate rows (16 bytes per input column, at most 2160 output rows) and the largest
/// output set (a 3840 x 2160 RGBA8 resized copy, its colour-converted copy and the encoded
/// bytes, 4 bytes per pixel each, doubled as a margin for the encoder).
pub fn peak_decode_bytes(w: u32, h: u32) -> u64 {
    let px = u64::from(w) * u64::from(h);
    let resample = u64::from(w) * 2160 * 16;
    let outputs = 3840u64 * 2160 * 4 * 3 * 2;
    px * (8 + 4) + resample + outputs
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Format {
    Png,
    Jpeg,
    Webp,
    Gif,
}

impl Format {
    fn name(self) -> &'static str {
        match self {
            Format::Png => "PNG",
            Format::Jpeg => "JPEG",
            Format::Webp => "WebP",
            Format::Gif => "GIF",
        }
    }
}

struct Output {
    /// File name stem; `.webp` is added.
    name: String,
    /// Canonical size; never upscaled.
    w: u32,
    h: u32,
}

struct Spec {
    max_bytes: u64,
    allow_jpeg: bool,
    /// Aspect ratio as (w, h) with 1 % tolerance, or None for the logo (any, at most 4:1 wide).
    aspect: Option<(u32, u32)>,
    min_w: u32,
    min_h: u32,
    keep_alpha: bool,
}

fn spec_for(slot: Slot) -> Spec {
    let (max_mb, jpeg, aspect, min_w, min_h, alpha) = match slot {
        Slot::Icon => (2, false, Some((1, 1)), 512, 512, true),
        Slot::Logo => (2, false, None, 1, 256, true),
        Slot::Hero => (8, true, Some((16, 9)), 1920, 1080, false),
        Slot::Cover => (4, true, Some((2, 3)), 600, 900, false),
        Slot::Screenshot(_) | Slot::TrailerPoster => (4, true, Some((16, 9)), 1280, 720, false),
        Slot::Trailer | Slot::Preview => unreachable!("video slots do not come here"),
    };
    Spec {
        max_bytes: max_mb * MIB,
        allow_jpeg: jpeg,
        aspect,
        min_w,
        min_h,
        keep_alpha: alpha,
    }
}

fn outputs_for(slot: Slot, sw: u32, sh: u32) -> Vec<Output> {
    let o = |name: String, w, h| Output { name, w, h };
    match slot {
        Slot::Icon => vec![
            o("icon-512".into(), 512, 512),
            o("icon-256".into(), 256, 256),
            o("icon-128".into(), 128, 128),
        ],
        // Logo: height capped at 512, width follows the aspect ratio (not in 05 before RUY-94).
        Slot::Logo => {
            let w = ((u64::from(sw) * 512) / u64::from(sh)).max(1) as u32;
            vec![o("logo".into(), w, 512)]
        }
        Slot::Hero => vec![
            o("hero-2160".into(), 3840, 2160),
            o("hero-1080".into(), 1920, 1080),
            o("card-540".into(), 960, 540),
        ],
        Slot::Cover => vec![o("cover-900".into(), 600, 900)],
        Slot::Screenshot(i) => vec![
            o(format!("screenshot-{i}-1080"), 1920, 1080),
            o(format!("screenshot-{i}-thumb"), 480, 270),
        ],
        Slot::TrailerPoster => vec![o("trailer-poster-1080".into(), 1920, 1080)],
        Slot::Trailer | Slot::Preview => vec![],
    }
}

fn detect(bytes: &[u8]) -> Result<Format, Fail> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Ok(Format::Png)
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Ok(Format::Jpeg)
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Ok(Format::Webp)
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Ok(Format::Gif)
    } else if looks_like_svg(bytes) {
        fail(codes::SVG, "SVG is not accepted")
    } else {
        fail(codes::FORMAT_UNSUPPORTED, "not a PNG, JPEG or WebP file")
    }
}

fn looks_like_svg(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(2048)];
    let text: String = head
        .iter()
        .map(|b| b.to_ascii_lowercase() as char)
        .collect();
    let t = text.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    t.contains("<svg") || t.starts_with("<?xml") || t.starts_with("<!doctype svg")
}

fn ext_format(path: &Path) -> Option<Format> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "png" => Some(Format::Png),
        "jpg" | "jpeg" => Some(Format::Jpeg),
        "webp" => Some(Format::Webp),
        "gif" => Some(Format::Gif),
        _ => None,
    }
}

/// The decoders are lenient with a cut-off file (a JPEG decodes as far as it goes), so the
/// container's own end marker is required: JPEG EOI, the RIFF length, the PNG IEND chunk.
fn check_complete(format: Format, bytes: &[u8]) -> Result<(), Fail> {
    let ok = match format {
        Format::Jpeg => {
            let end = bytes.iter().rposition(|b| *b != 0).map_or(0, |i| i + 1);
            bytes[..end].ends_with(&[0xFF, 0xD9])
        }
        Format::Webp => {
            bytes.len() >= 12
                && u64::from(u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]])) + 8
                    <= bytes.len() as u64
        }
        Format::Png => bytes.len() >= 12 && &bytes[bytes.len() - 8..bytes.len() - 4] == b"IEND",
        Format::Gif => true,
    };
    if ok {
        Ok(())
    } else {
        fail(codes::CORRUPT, "the file is cut off (no end marker)")
    }
}

fn aspect_ok(w: u32, h: u32, (aw, ah): (u32, u32)) -> bool {
    // |w/h - aw/ah| <= 1 % of aw/ah, in integers.
    let lhs = u64::from(w) * u64::from(ah);
    let rhs = u64::from(h) * u64::from(aw);
    lhs.abs_diff(rhs) * 100 <= rhs
}

fn swaps_axes(o: Orientation) -> bool {
    matches!(
        o,
        Orientation::Rotate90
            | Orientation::Rotate270
            | Orientation::Rotate90FlipH
            | Orientation::Rotate270FlipH
    )
}

pub(crate) fn vet_image(slot: Slot, path: &Path, out_dir: &Path) -> Result<Vec<PathBuf>, Fail> {
    let spec = spec_for(slot);
    let meta = std::fs::symlink_metadata(path).map_err(|e| Fail {
        code: codes::IO,
        message: format!("{}: {e}", path.display()),
    })?;
    if !meta.is_file() {
        return fail(codes::NOT_A_FILE, "not a regular file");
    }
    if meta.len() > spec.max_bytes {
        return fail(
            codes::FILE_TOO_LARGE,
            format!("{} bytes, at most {}", meta.len(), spec.max_bytes),
        );
    }
    let bytes = std::fs::read(path).map_err(|e| Fail {
        code: codes::IO,
        message: e.to_string(),
    })?;

    let format = detect(&bytes)?;
    if let Some(claimed) = ext_format(path) {
        if claimed != format {
            return fail(
                codes::MAGIC_MISMATCH,
                format!(
                    "extension says {}, the content is {}",
                    claimed.name(),
                    format.name()
                ),
            );
        }
    }
    let allowed = match format {
        Format::Png | Format::Webp => true,
        Format::Jpeg => spec.allow_jpeg,
        Format::Gif => false,
    };
    if !allowed {
        return fail(
            codes::FORMAT_UNSUPPORTED,
            format!("{} is not accepted for {}", format.name(), slot.key()),
        );
    }

    check_complete(format, &bytes)?;
    let corrupt = |e: image::ImageError| Fail {
        code: codes::CORRUPT,
        message: e.to_string(),
    };
    let cur = Cursor::new(bytes.as_slice());
    let (img, icc) = match format {
        Format::Png => {
            let dec = PngDecoder::new(cur).map_err(corrupt)?;
            if dec.is_apng().map_err(corrupt)? {
                return fail(codes::ANIMATED, "animated PNG");
            }
            header_then_decode(dec, &spec, slot)?
        }
        Format::Jpeg => header_then_decode(JpegDecoder::new(cur).map_err(corrupt)?, &spec, slot)?,
        Format::Webp => {
            let dec = WebPDecoder::new(cur).map_err(corrupt)?;
            if dec.has_animation() {
                return fail(codes::ANIMATED, "animated WebP");
            }
            header_then_decode(dec, &spec, slot)?
        }
        Format::Gif => unreachable!("refused above"),
    };
    drop(bytes);

    let transform = match icc {
        Some(profile) => Some(srgb_transform(&profile)?),
        None => None,
    };
    let (sw, sh) = (img.width(), img.height());
    let mut written: Vec<(PathBuf, Vec<u8>)> = Vec::new();
    for out in outputs_for(slot, sw, sh) {
        // Never upscale: a source smaller than the canonical size keeps its width.
        let (tw, th) = if sw >= out.w && sh >= out.h {
            (out.w, out.h)
        } else {
            let tw = sw.min(out.w);
            let th = ((u64::from(tw) * u64::from(out.h)) / u64::from(out.w)).max(1) as u32;
            (tw, th)
        };
        let mut px = if (tw, th) == (sw, sh) {
            img.clone()
        } else {
            image::imageops::resize(&img, tw, th, FilterType::Lanczos3)
        };
        if let Some(t) = &transform {
            let mut dst = vec![0u8; px.as_raw().len()];
            t.transform(px.as_raw(), &mut dst).map_err(|e| Fail {
                code: codes::COLOUR_PROFILE,
                message: format!("colour conversion failed: {e}"),
            })?;
            px = RgbaImage::from_raw(tw, th, dst).ok_or_else(|| Fail {
                code: codes::COLOUR_PROFILE,
                message: "colour conversion changed the size".into(),
            })?;
        }
        let webp = encode_webp(&px, spec.keep_alpha)?;
        written.push((out_dir.join(format!("{}.webp", out.name)), webp));
    }
    write_all(out_dir, written)
}

/// Check the header (size limits, minimum size, aspect), then and only then decode the pixels.
fn header_then_decode<D: ImageDecoder>(
    mut dec: D,
    spec: &Spec,
    slot: Slot,
) -> Result<(RgbaImage, Option<Vec<u8>>), Fail> {
    let (mut w, mut h) = dec.dimensions();
    let orientation = dec.orientation().unwrap_or(Orientation::NoTransforms);
    if swaps_axes(orientation) {
        std::mem::swap(&mut w, &mut h);
    }
    if w == 0 || h == 0 {
        return fail(codes::CORRUPT, "zero-sized image");
    }
    if w > MAX_DIMENSION || h > MAX_DIMENSION || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return fail(
            codes::DIMENSIONS_TOO_LARGE,
            format!("{w}x{h}: at most {MAX_DIMENSION}x{MAX_DIMENSION} and {MAX_PIXELS} pixels"),
        );
    }
    if w < spec.min_w || h < spec.min_h {
        return fail(
            codes::TOO_SMALL,
            format!(
                "{w}x{h} for {}: at least {}x{}",
                slot.key(),
                spec.min_w,
                spec.min_h
            ),
        );
    }
    match spec.aspect {
        Some(a) if !aspect_ok(w, h, a) => {
            return fail(
                codes::ASPECT_RATIO,
                format!("{w}x{h} for {}: needs {}:{} (+-1 %)", slot.key(), a.0, a.1),
            )
        }
        None if u64::from(w) > 4 * u64::from(h) => {
            return fail(codes::ASPECT_RATIO, format!("{w}x{h}: at most 4:1 wide"))
        }
        _ => {}
    }
    let icc = dec.icc_profile().unwrap_or(None);
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_DIMENSION);
    limits.max_image_height = Some(MAX_DIMENSION);
    limits.max_alloc = Some(1024 * MIB);
    dec.set_limits(limits).map_err(|e| Fail {
        code: codes::CORRUPT,
        message: e.to_string(),
    })?;

    DECODES.with(|c| c.set(c.get() + 1));
    let mut img = DynamicImage::from_decoder(dec).map_err(|e| Fail {
        code: codes::CORRUPT,
        message: e.to_string(),
    })?;
    img.apply_orientation(orientation);
    Ok((img.into_rgba8(), icc))
}

fn srgb_transform(icc: &[u8]) -> Result<std::sync::Arc<moxcms::Transform8BitExecutor>, Fail> {
    let bad = |m: String| Fail {
        code: codes::COLOUR_PROFILE,
        message: m,
    };
    let src = moxcms::ColorProfile::new_from_slice(icc)
        .map_err(|e| bad(format!("unreadable ICC profile: {e}")))?;
    if src.color_space != moxcms::DataColorSpace::Rgb {
        return Err(bad("only RGB ICC profiles are accepted".into()));
    }
    src.create_transform_8bit(
        moxcms::Layout::Rgba,
        &moxcms::ColorProfile::new_srgb(),
        moxcms::Layout::Rgba,
        moxcms::TransformOptions::default(),
    )
    .map_err(|e| bad(format!("unsupported ICC profile: {e}")))
}

fn encode_webp(px: &RgbaImage, keep_alpha: bool) -> Result<Vec<u8>, Fail> {
    let (w, h) = px.dimensions();
    let mut out = Vec::new();
    let enc = WebPEncoder::new_lossless(&mut out);
    let r = if keep_alpha {
        enc.encode(px.as_raw(), w, h, ExtendedColorType::Rgba8)
    } else {
        // Opaque slots: composite over black and drop the alpha channel.
        let mut rgb = Vec::with_capacity(px.as_raw().len() / 4 * 3);
        for p in px.as_raw().chunks_exact(4) {
            let a = u32::from(p[3]);
            for c in &p[..3] {
                rgb.push(((u32::from(*c) * a + 127) / 255) as u8);
            }
        }
        enc.encode(&rgb, w, h, ExtendedColorType::Rgb8)
    };
    r.map_err(|e| Fail {
        code: codes::IO,
        message: format!("WebP encode: {e}"),
    })?;
    Ok(out)
}

/// Write the finished files (tmp + rename), only after every output was encoded.
pub(crate) fn write_all(
    out_dir: &Path,
    files: Vec<(PathBuf, Vec<u8>)>,
) -> Result<Vec<PathBuf>, Fail> {
    let io = |e: std::io::Error| Fail {
        code: codes::IO,
        message: e.to_string(),
    };
    std::fs::create_dir_all(out_dir).map_err(io)?;
    let mut done = Vec::new();
    for (path, data) in files {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, data).map_err(io)?;
        std::fs::rename(&tmp, &path).map_err(io)?;
        done.push(path);
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aspect_tolerance_is_one_percent() {
        assert!(aspect_ok(1920, 1080, (16, 9)));
        assert!(aspect_ok(1920, 1090, (16, 9))); // 0.9 % off
        assert!(!aspect_ok(1920, 1100, (16, 9))); // 1.8 % off
        assert!(aspect_ok(600, 900, (2, 3)));
        assert!(!aspect_ok(1000, 1000, (2, 3)));
    }

    #[test]
    fn largest_allowed_image_stays_under_the_stated_bound() {
        // 8192 x 8192 is exactly MAX_PIXELS. Worst case: a 16-bit RGBA native buffer (512 MiB),
        // the RGBA8 copy (256 MiB), the resampler rows (8192 * 2160 * 16 = 270 MiB) and the
        // output set (3840 * 2160 * 24 = 190 MiB): 1228 MiB, stated bound 1.25 GiB.
        assert_eq!(
            u64::from(MAX_DIMENSION) * u64::from(MAX_DIMENSION),
            MAX_PIXELS
        );
        let peak = peak_decode_bytes(MAX_DIMENSION, MAX_DIMENSION);
        assert_eq!(peak, MAX_PIXELS * 12 + 8192 * 2160 * 16 + 3840 * 2160 * 24);
        assert!(peak < 1280 * MIB, "peak {} MiB", peak / MIB);
        // The decoder's own allocation limit (1 GiB) covers the native buffer plus its copy.
        const { assert!(MAX_PIXELS * 12 <= 1024 * MIB) };
    }
}
