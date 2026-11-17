//! A tiny PNG writer: one solid colour, 8-bit RGBA, no metadata. `init` writes the 64x64
//! placeholder icon with it (too small on purpose, so `validate` fails until it is replaced); the
//! tests write the fixture art with it.

use flate2::write::ZlibEncoder;
use flate2::{Compression, Crc};
use std::io::Write;

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc = Crc::new();
    crc.update(kind);
    crc.update(data);
    out.extend_from_slice(&crc.sum().to_be_bytes());
}

/// A `w` x `h` PNG filled with `rgba`.
pub fn solid(w: u32, h: u32, rgba: [u8; 4]) -> Vec<u8> {
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8 bit, RGBA, deflate, adaptive, no interlace
    chunk(&mut out, b"IHDR", &ihdr);

    let mut row = Vec::with_capacity(1 + 4 * w as usize);
    row.push(0); // filter: none
    for _ in 0..w {
        row.extend_from_slice(&rgba);
    }
    let mut z = ZlibEncoder::new(Vec::new(), Compression::default());
    for _ in 0..h {
        // Writing to a Vec cannot fail.
        let _ = z.write_all(&row);
    }
    let idat = z.finish().unwrap_or_default();
    chunk(&mut out, b"IDAT", &idat);
    chunk(&mut out, b"IEND", &[]);
    out
}
