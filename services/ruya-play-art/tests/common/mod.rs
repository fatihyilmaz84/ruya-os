//! Fixtures generated in code (never binary blobs).
#![allow(dead_code)]

use std::io::Cursor;
use std::path::{Path, PathBuf};

use image::codecs::png::PngEncoder;
use image::{DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, Rgb, RgbImage};
use ruya_play_art::{Outcome, Slot, SlotResult};

/// A smooth gradient, optionally with deterministic noise (a photo-like worst case for the
/// lossless encoder).
pub fn gradient(w: u32, h: u32, noise: bool) -> RgbImage {
    let mut seed = 0x2545_F491u32;
    RgbImage::from_fn(w, h, |x, y| {
        let mut n = 0i32;
        if noise {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            n = ((seed >> 24) % 17) as i32 - 8;
        }
        let c = |v: u32| (v as i32 + n).clamp(0, 255) as u8;
        Rgb([c(x * 255 / w), c(y * 255 / h), c((x + y) * 255 / (w + h))])
    })
}

pub fn encode(img: RgbImage, f: ImageFormat) -> Vec<u8> {
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(img).write_to(&mut out, f).unwrap();
    out.into_inner()
}

pub fn png(w: u32, h: u32) -> Vec<u8> {
    encode(gradient(w, h, false), ImageFormat::Png)
}

pub fn jpeg(w: u32, h: u32) -> Vec<u8> {
    encode(gradient(w, h, false), ImageFormat::Jpeg)
}

pub fn webp(w: u32, h: u32) -> Vec<u8> {
    encode(gradient(w, h, false), ImageFormat::WebP)
}

/// A solid-colour PNG that carries an ICC profile.
pub fn png_with_icc(w: u32, h: u32, rgb: [u8; 3], icc: Vec<u8>) -> Vec<u8> {
    let raw: Vec<u8> = (0..w * h).flat_map(|_| rgb).collect();
    let mut out = Vec::new();
    let mut enc = PngEncoder::new(&mut out);
    enc.set_icc_profile(icc).unwrap();
    enc.write_image(&raw, w, h, ExtendedColorType::Rgb8)
        .unwrap();
    out
}

pub fn crc32(data: &[u8]) -> u32 {
    crc32fast::hash(data)
}

pub fn png_chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let mut body = kind.to_vec();
    body.extend_from_slice(data);
    v.extend_from_slice(&body);
    v.extend_from_slice(&crc32(&body).to_be_bytes());
    v
}

/// Insert a chunk before the first IDAT.
pub fn png_insert_before_idat(png: &[u8], chunk: &[u8]) -> Vec<u8> {
    let at = png.windows(4).position(|w| w == b"IDAT").unwrap() - 4;
    let mut v = png[..at].to_vec();
    v.extend_from_slice(chunk);
    v.extend_from_slice(&png[at..]);
    v
}

/// A PNG whose header claims `w` x `h` and whose pixel data is a few bytes: a decompression
/// bomb. Valid up to the first IDAT, so only a header check can refuse it.
pub fn png_bomb(w: u32, h: u32) -> Vec<u8> {
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // 8 bit, RGB
    let mut v = b"\x89PNG\r\n\x1a\n".to_vec();
    v.extend(png_chunk(b"IHDR", &ihdr));
    v.extend(png_chunk(b"IDAT", &[0x78, 0x9c, 0x03, 0, 0, 0, 0, 1]));
    v.extend(png_chunk(b"IEND", &[]));
    v
}

/// RIFF/WebP chunk list.
pub fn riff(chunks: &[(&[u8; 4], Vec<u8>)]) -> Vec<u8> {
    let mut body = b"WEBP".to_vec();
    for (k, d) in chunks {
        body.extend_from_slice(*k);
        body.extend_from_slice(&(d.len() as u32).to_le_bytes());
        body.extend_from_slice(d);
        if d.len() % 2 == 1 {
            body.push(0);
        }
    }
    let mut v = b"RIFF".to_vec();
    v.extend_from_slice(&(body.len() as u32).to_le_bytes());
    v.extend(body);
    v
}

fn le24(v: u32) -> [u8; 3] {
    [v as u8, (v >> 8) as u8, (v >> 16) as u8]
}

/// The payload of the VP8L chunk of a simple lossless WebP.
pub fn vp8l_payload(webp: &[u8]) -> Vec<u8> {
    let at = webp.windows(4).position(|w| w == b"VP8L").unwrap();
    let len = u32::from_le_bytes(webp[at + 4..at + 8].try_into().unwrap()) as usize;
    webp[at + 8..at + 8 + len].to_vec()
}

/// An animated WebP: VP8X with the animation flag, ANIM, and one ANMF frame holding a real
/// VP8L image.
pub fn animated_webp(w: u32, h: u32) -> Vec<u8> {
    let still = encode(
        RgbImage::from_pixel(w, h, Rgb([10, 20, 30])),
        ImageFormat::WebP,
    );
    let frame_img = vp8l_payload(&still);
    let mut vp8x = vec![0x02, 0, 0, 0];
    vp8x.extend(le24(w - 1));
    vp8x.extend(le24(h - 1));
    let anim = vec![0, 0, 0, 0, 0, 0];
    let mut anmf = Vec::new();
    anmf.extend(le24(0));
    anmf.extend(le24(0));
    anmf.extend(le24(w - 1));
    anmf.extend(le24(h - 1));
    anmf.extend(le24(100));
    anmf.push(0);
    anmf.extend_from_slice(b"VP8L");
    anmf.extend_from_slice(&(frame_img.len() as u32).to_le_bytes());
    anmf.extend(&frame_img);
    if frame_img.len() % 2 == 1 {
        anmf.push(0);
    }
    riff(&[(b"VP8X", vp8x), (b"ANIM", anim), (b"ANMF", anmf)])
}

/// A still WebP (VP8X + VP8L) whose header claims `w` x `h`.
pub fn webp_bomb(w: u32, h: u32) -> Vec<u8> {
    let mut vp8x = vec![0, 0, 0, 0];
    vp8x.extend(le24(w - 1));
    vp8x.extend(le24(h - 1));
    let bits = (w - 1) | ((h - 1) << 14);
    let mut vp8l = vec![0x2f];
    vp8l.extend_from_slice(&bits.to_le_bytes());
    vp8l.extend_from_slice(&[0, 0, 0, 0]);
    riff(&[(b"VP8X", vp8x), (b"VP8L", vp8l)])
}

/// Insert an APP1 (Exif) segment right after SOI.
pub fn jpeg_with_exif(jpeg: &[u8], tiff: &[u8]) -> Vec<u8> {
    let mut seg = b"Exif\0\0".to_vec();
    seg.extend_from_slice(tiff);
    let mut v = jpeg[..2].to_vec();
    v.extend_from_slice(&[0xFF, 0xE1]);
    v.extend_from_slice(&((seg.len() + 2) as u16).to_be_bytes());
    v.extend(seg);
    v.extend_from_slice(&jpeg[2..]);
    v
}

/// Little-endian TIFF with an orientation tag and a GPS-looking sentinel string after the IFD.
pub fn tiff(orientation: u16, sentinel: &[u8]) -> Vec<u8> {
    let mut t = b"II*\0".to_vec();
    t.extend_from_slice(&8u32.to_le_bytes());
    t.extend_from_slice(&1u16.to_le_bytes());
    t.extend_from_slice(&0x0112u16.to_le_bytes());
    t.extend_from_slice(&3u16.to_le_bytes());
    t.extend_from_slice(&1u32.to_le_bytes());
    t.extend_from_slice(&orientation.to_le_bytes());
    t.extend_from_slice(&[0, 0]);
    t.extend_from_slice(&0u32.to_le_bytes());
    t.extend_from_slice(sentinel);
    t
}

pub fn write(dir: &Path, name: &str, data: &[u8]) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, data).unwrap();
    p
}

pub fn run(slot: Slot, path: PathBuf, out: &Path) -> Outcome {
    let mut r: Vec<SlotResult> = ruya_play_art::vet(&[(slot, path)], out);
    r.remove(0).outcome
}

pub fn code(o: &Outcome) -> &'static str {
    match o {
        Outcome::Invalid { code, .. } => code,
        other => panic!("expected Invalid, got {other:?}"),
    }
}

pub fn files(o: &Outcome) -> Vec<PathBuf> {
    match o {
        Outcome::Ok { files } => files.clone(),
        other => panic!("expected Ok, got {other:?}"),
    }
}

pub fn dims(p: &Path) -> (u32, u32) {
    image::image_dimensions(p).unwrap()
}
