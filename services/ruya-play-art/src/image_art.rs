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

use crate::{codes, fail, open_regular, read_limited, Fail, Slot};

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

/// Limits given to a decoder: the dimension limits and a 1 GiB allocation budget. They hold
/// for the pixel decode; metadata chunks are bounded by `scan_png` and `scan_webp` instead.
fn decode_limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_DIMENSION);
    limits.max_image_height = Some(MAX_DIMENSION);
    limits.max_alloc = Some(1024 * MIB);
    limits
}

/// Largest ICC profile accepted, compressed or not.
const MAX_ICC: usize = 2 * 1024 * 1024;

struct PngScan {
    /// IHDR, PLTE, tRNS, IDAT and IEND only.
    clean: Vec<u8>,
    /// The inflated iCCP profile, within `MAX_ICC`.
    icc: Option<Vec<u8>>,
}

fn scan_png(bytes: &[u8]) -> Result<PngScan, Fail> {
    let cut = || Fail {
        code: codes::CORRUPT,
        message: "PNG chunk list is cut off or malformed".into(),
    };
    let mut clean = bytes[..8].to_vec();
    let mut icc = None;
    let mut pos = 8usize;
    let mut ended = false;
    while bytes.len() - pos >= 12 {
        let len = u32::from_be_bytes([bytes[pos], bytes[pos + 1], bytes[pos + 2], bytes[pos + 3]])
            as usize;
        if len > bytes.len() - pos - 12 {
            return Err(cut());
        }
        let kind = &bytes[pos + 4..pos + 8];
        let whole = &bytes[pos..pos + 12 + len];
        let data = &bytes[pos + 8..pos + 8 + len];
        match kind {
            b"IHDR" | b"PLTE" | b"tRNS" | b"IDAT" => clean.extend_from_slice(whole),
            b"IEND" => {
                clean.extend_from_slice(whole);
                ended = true;
                break;
            }
            b"acTL" => return fail(codes::ANIMATED, "animated PNG"),
            b"iCCP" if icc.is_none() => icc = Some(inflate_iccp(data)?),
            _ => {}
        }
        pos += 12 + len;
    }
    if !ended {
        return Err(cut());
    }
    Ok(PngScan { clean, icc })
}

fn inflate_iccp(data: &[u8]) -> Result<Vec<u8>, Fail> {
    let bad = |m: &str| Fail {
        code: codes::COLOUR_PROFILE,
        message: m.to_string(),
    };
    let name_end = data
        .iter()
        .position(|b| *b == 0)
        .ok_or_else(|| bad("bad iCCP chunk"))?;
    if name_end == 0 || name_end > 79 || data.get(name_end + 1) != Some(&0) {
        return Err(bad("bad iCCP chunk"));
    }
    match miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&data[name_end + 2..], MAX_ICC) {
        Ok(v) => Ok(v),
        Err(e) if e.status == miniz_oxide::inflate::TINFLStatus::HasMoreOutput => fail(
            codes::ICC_TOO_LARGE,
            format!("the ICC profile inflates to more than {MAX_ICC} bytes"),
        ),
        Err(_) => Err(bad("the iCCP data does not inflate")),
    }
}

/// Every RIFF chunk must lie inside the file (the decoder allocates a chunk's declared size
/// before reading it) and the ICC profile is bounded.
fn scan_webp(bytes: &[u8]) -> Result<(), Fail> {
    let mut pos = 12usize;
    while bytes.len() - pos.min(bytes.len()) >= 8 {
        let size = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        if size > bytes.len() - pos - 8 {
            return fail(codes::CORRUPT, "WebP chunk runs past the end of the file");
        }
        if &bytes[pos..pos + 4] == b"ICCP" && size > MAX_ICC {
            return fail(codes::ICC_TOO_LARGE, "the ICC profile is too large");
        }
        pos += 8 + size + (size & 1);
    }
    Ok(())
}

/// Centre-crop to the exact ratio `aw:ah` (the largest whole multiple that fits), in place.
/// A source inside the 1 % tolerance is cropped, never stretched.
fn crop_to_aspect(img: RgbaImage, (aw, ah): (u32, u32)) -> RgbaImage {
    let (w, h) = img.dimensions();
    let k = (w / aw).min(h / ah).max(1);
    let (cw, ch) = (k * aw, k * ah);
    if (cw, ch) == (w, h) {
        return img;
    }
    let (x0, y0) = ((w - cw) as usize / 2, (h - ch) as usize / 2);
    let (w, cw, ch) = (w as usize, cw as usize, ch as usize);
    let mut raw = img.into_raw();
    for row in 0..ch {
        let src = ((y0 + row) * w + x0) * 4;
        raw.copy_within(src..src + cw * 4, row * cw * 4);
    }
    raw.truncate(cw * ch * 4);
    RgbaImage::from_raw(cw as u32, ch as u32, raw).expect("buffer length was just set")
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
    let (mut file, size) = open_regular(path, codes::NOT_A_FILE, codes::IO)?;
    if size > spec.max_bytes {
        return fail(
            codes::FILE_TOO_LARGE,
            format!("{size} bytes, at most {}", spec.max_bytes),
        );
    }
    let bytes = read_limited(&mut file, spec.max_bytes, codes::FILE_TOO_LARGE, codes::IO)?;
    drop(file);

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
        // a decoder that checks the dimension limits itself, before any pixel
        code: if matches!(e, image::ImageError::Limits(_)) {
            codes::DIMENSIONS_TOO_LARGE
        } else {
            codes::CORRUPT
        },
        message: e.to_string(),
    };
    let (img, icc) = match format {
        Format::Png => {
            // Rebuilt from the chunks the decoder needs: the decoder inflates iCCP and compressed
            // text chunks without a budget we could rely on (and drops an over-budget iCCP
            // silently), so those chunks never reach it.
            let scan = scan_png(&bytes)?;
            let dec = PngDecoder::with_limits(Cursor::new(scan.clean.as_slice()), decode_limits())
                .map_err(corrupt)?;
            let (img, _) = header_then_decode(dec, &spec, slot)?;
            (img, scan.icc)
        }
        Format::Jpeg => {
            let dec = JpegDecoder::new(Cursor::new(bytes.as_slice())).map_err(corrupt)?;
            header_then_decode(dec, &spec, slot)?
        }
        Format::Webp => {
            scan_webp(&bytes)?;
            let dec = WebPDecoder::new(Cursor::new(bytes.as_slice())).map_err(corrupt)?;
            if dec.has_animation() {
                return fail(codes::ANIMATED, "animated WebP");
            }
            header_then_decode(dec, &spec, slot)?
        }
        Format::Gif => unreachable!("refused above"),
    };
    drop(bytes);

    let img = match spec.aspect {
        Some(a) => crop_to_aspect(img, a),
        None => img,
    };
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
    dec.set_limits(decode_limits()).map_err(|e| Fail {
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
    fn crop_is_centred_and_exact() {
        let img = RgbaImage::from_fn(35, 20, |x, y| image::Rgba([x as u8, y as u8, 0, 255]));
        let c = crop_to_aspect(img, (16, 9)); // k = min(2, 2) = 2 -> 32x18, offset (1, 1)
        assert_eq!(c.dimensions(), (32, 18));
        assert_eq!(c.get_pixel(0, 0).0, [1, 1, 0, 255]);
        assert_eq!(c.get_pixel(31, 17).0, [32, 18, 0, 255]);
        let sq = crop_to_aspect(RgbaImage::new(10, 7), (1, 1));
        assert_eq!(sq.dimensions(), (7, 7));
    }

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
