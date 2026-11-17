//! The deterministic zip writer (05 section 13). The same entries give the same bytes: entries are
//! written sorted by name, every timestamp is 1980-01-01 00:00:00, there are no comments and no
//! extra fields except ZIP64 where a size or offset needs it, and the Unix mode is the only
//! attribute (0644, 0755 with the executable bit, 0755 for a folder).
//!
//! Entries are stored by default (payloads are compressed already and the console reads stored
//! zips faster); `deflate` compresses with flate2 (miniz_oxide) at its default level, and writes a
//! data descriptor so a big file is streamed, not held in memory.

use flate2::write::DeflateEncoder;
use flate2::{Compression, Crc};
use ruya_play_format::Source;
use std::io::{self, Read, Write};
use std::path::PathBuf;

/// Where an entry's bytes come from.
pub enum FileSrc<'a> {
    /// Held in memory.
    Bytes(Vec<u8>),
    /// A file on disk, read when the zip is written.
    Path(PathBuf),
    /// A file of another package form.
    Source(&'a dyn Source, String),
}

impl FileSrc<'_> {
    fn open(&self) -> io::Result<Box<dyn Read + '_>> {
        match self {
            FileSrc::Bytes(b) => Ok(Box::new(io::Cursor::new(b.as_slice()))),
            FileSrc::Path(p) => Ok(Box::new(std::fs::File::open(p)?)),
            FileSrc::Source(s, name) => s.open(name),
        }
    }
}

/// One entry to write.
pub enum Item<'a> {
    /// An empty folder (written as `name/`).
    Dir,
    /// A regular file.
    File {
        /// The bytes.
        src: FileSrc<'a>,
        /// Its size, as the caller measured it.
        size: u64,
        /// Its CRC-32 when known (saves reading a stored file twice).
        crc: Option<u32>,
        /// The executable bit.
        executable: bool,
    },
}

/// An entry with its name.
pub struct Entry<'a> {
    /// Package path, `/` separated, without a trailing slash.
    pub name: String,
    /// What it is.
    pub item: Item<'a>,
}

/// Options of [`write_zip`].
#[derive(Debug, Clone, Copy)]
pub struct Options {
    /// Compress entries (default stored).
    pub deflate: bool,
    /// Entries of this size and above get ZIP64 fields; the end record is ZIP64 when anything
    /// needs it. The default is just below the 32-bit limit; tests lower it to cover the path.
    pub zip64_at: u64,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            deflate: false,
            zip64_at: 0xF000_0000,
        }
    }
}

/// 1980-01-01 in DOS date form; the time is 00:00:00.
const DOS_DATE: u16 = (1 << 5) | 1;
const FLAG_UTF8: u16 = 0x0800;
const FLAG_DESCRIPTOR: u16 = 0x0008;

struct Counting<W: Write> {
    inner: W,
    count: u64,
}

impl<W: Write> Write for Counting<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.count += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

struct Done {
    name: String,
    flags: u16,
    method: u16,
    crc: u32,
    csize: u64,
    usize_: u64,
    offset: u64,
    external: u32,
    zip64: bool,
}

fn crc_of(src: &FileSrc<'_>) -> io::Result<u32> {
    let mut r = src.open()?;
    let (mut crc, mut buf) = (Crc::new(), vec![0u8; 256 * 1024]);
    loop {
        let n = r.read(&mut buf)?;
        if n == 0 {
            return Ok(crc.sum());
        }
        crc.update(&buf[..n]);
    }
}

fn w16(v: &mut Vec<u8>, x: u16) {
    v.extend_from_slice(&x.to_le_bytes());
}
fn w32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_le_bytes());
}
fn w64(v: &mut Vec<u8>, x: u64) {
    v.extend_from_slice(&x.to_le_bytes());
}

fn flags_of(name: &str) -> u16 {
    if name.is_ascii() {
        0
    } else {
        FLAG_UTF8
    }
}

/// Write the zip of `entries` (sorted here by name, bytewise) to `out`. Returns the bytes written.
pub fn write_zip<W: Write>(out: W, entries: Vec<Entry<'_>>, opts: Options) -> io::Result<u64> {
    let mut entries = entries;
    entries.sort_by(|a, b| a.name.as_bytes().cmp(b.name.as_bytes()));
    let mut w = Counting {
        inner: io::BufWriter::new(out),
        count: 0,
    };
    let mut done: Vec<Done> = Vec::with_capacity(entries.len());
    for e in &entries {
        let offset = w.count;
        match &e.item {
            Item::Dir => {
                let name = format!("{}/", e.name);
                let flags = flags_of(&name);
                let mut h = Vec::new();
                local_header(&mut h, &name, flags, 0, 0, 0, 0, false);
                w.write_all(&h)?;
                done.push(Done {
                    name,
                    flags,
                    method: 0,
                    crc: 0,
                    csize: 0,
                    usize_: 0,
                    offset,
                    external: (0o040755 << 16) | 0x10,
                    zip64: false,
                });
            }
            Item::File {
                src,
                size,
                crc,
                executable,
            } => {
                let zip64 = *size >= opts.zip64_at;
                let external = (if *executable { 0o100755 } else { 0o100644 }) << 16;
                if opts.deflate && *size > 0 {
                    let flags = flags_of(&e.name) | FLAG_DESCRIPTOR;
                    let mut h = Vec::new();
                    local_header(&mut h, &e.name, flags, 8, 0, 0, 0, zip64);
                    w.write_all(&h)?;
                    let start = w.count;
                    let mut enc = DeflateEncoder::new(&mut w, Compression::default());
                    let (mut crc_acc, mut total) = (Crc::new(), 0u64);
                    let mut r = src.open()?;
                    let mut buf = vec![0u8; 256 * 1024];
                    loop {
                        let n = r.read(&mut buf)?;
                        if n == 0 {
                            break;
                        }
                        crc_acc.update(&buf[..n]);
                        total += n as u64;
                        enc.write_all(&buf[..n])?;
                    }
                    enc.finish()?;
                    let csize = w.count - start;
                    let mut d = Vec::new();
                    w32(&mut d, 0x0807_4b50);
                    w32(&mut d, crc_acc.sum());
                    if zip64 {
                        w64(&mut d, csize);
                        w64(&mut d, total);
                    } else {
                        w32(&mut d, csize as u32);
                        w32(&mut d, total as u32);
                    }
                    w.write_all(&d)?;
                    done.push(Done {
                        name: e.name.clone(),
                        flags,
                        method: 8,
                        crc: crc_acc.sum(),
                        csize,
                        usize_: total,
                        offset,
                        external,
                        zip64,
                    });
                } else {
                    let crc = match crc {
                        Some(c) => *c,
                        None => crc_of(src)?,
                    };
                    let flags = flags_of(&e.name);
                    let mut h = Vec::new();
                    local_header(&mut h, &e.name, flags, 0, crc, *size, *size, zip64);
                    w.write_all(&h)?;
                    let copied = io::copy(&mut src.open()?, &mut w)?;
                    if copied != *size {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            format!("{} changed while the zip was written", e.name),
                        ));
                    }
                    done.push(Done {
                        name: e.name.clone(),
                        flags,
                        method: 0,
                        crc,
                        csize: *size,
                        usize_: *size,
                        offset,
                        external,
                        zip64,
                    });
                }
            }
        }
    }
    let cd_start = w.count;
    for d in &done {
        let mut c = Vec::new();
        let big_off = d.offset >= 0xFFFF_FFFF;
        let z = d.zip64 || big_off;
        w32(&mut c, 0x0201_4b50);
        w16(&mut c, (3 << 8) | if z { 45 } else { 20 }); // made by: Unix
        w16(&mut c, if z { 45 } else { 20 });
        w16(&mut c, d.flags);
        w16(&mut c, d.method);
        w16(&mut c, 0);
        w16(&mut c, DOS_DATE);
        w32(&mut c, d.crc);
        let sat = |big: bool, v: u64| if big { 0xFFFF_FFFF } else { v as u32 };
        w32(&mut c, sat(d.zip64, d.csize));
        w32(&mut c, sat(d.zip64, d.usize_));
        w16(&mut c, d.name.len() as u16);
        let mut extra = Vec::new();
        if z {
            let mut e = Vec::new();
            if d.zip64 {
                w64(&mut e, d.usize_);
                w64(&mut e, d.csize);
            }
            if big_off {
                w64(&mut e, d.offset);
            }
            w16(&mut extra, 1);
            w16(&mut extra, e.len() as u16);
            extra.extend_from_slice(&e);
        }
        w16(&mut c, extra.len() as u16);
        w16(&mut c, 0); // comment
        w16(&mut c, 0); // disk
        w16(&mut c, 0); // internal attributes
        w32(&mut c, d.external);
        w32(&mut c, sat(big_off, d.offset));
        c.extend_from_slice(d.name.as_bytes());
        c.extend_from_slice(&extra);
        w.write_all(&c)?;
    }
    let cd_size = w.count - cd_start;
    let n = done.len() as u64;
    let need64 = n >= 0xFFFF
        || cd_start >= 0xFFFF_FFFF
        || cd_size >= 0xFFFF_FFFF
        || (opts.zip64_at == 0 && n > 0);
    let mut end = Vec::new();
    if need64 {
        let rec_off = w.count;
        w32(&mut end, 0x0606_4b50);
        w64(&mut end, 44);
        w16(&mut end, (3 << 8) | 45);
        w16(&mut end, 45);
        w32(&mut end, 0);
        w32(&mut end, 0);
        w64(&mut end, n);
        w64(&mut end, n);
        w64(&mut end, cd_size);
        w64(&mut end, cd_start);
        w32(&mut end, 0x0706_4b50);
        w32(&mut end, 0);
        w64(&mut end, rec_off);
        w32(&mut end, 1);
    }
    w32(&mut end, 0x0605_4b50);
    w16(&mut end, 0);
    w16(&mut end, 0);
    let sat16 = |v: u64| if need64 { 0xFFFF } else { v as u16 };
    let sat32 = |v: u64| if need64 { 0xFFFF_FFFF } else { v as u32 };
    w16(&mut end, sat16(n));
    w16(&mut end, sat16(n));
    w32(&mut end, sat32(cd_size));
    w32(&mut end, sat32(cd_start));
    w16(&mut end, 0);
    w.write_all(&end)?;
    w.flush()?;
    Ok(w.count)
}

#[allow(clippy::too_many_arguments)]
fn local_header(
    h: &mut Vec<u8>,
    name: &str,
    flags: u16,
    method: u16,
    crc: u32,
    csize: u64,
    usize_: u64,
    zip64: bool,
) {
    w32(h, 0x0403_4b50);
    w16(h, if zip64 { 45 } else { 20 });
    w16(h, flags);
    w16(h, method);
    w16(h, 0);
    w16(h, DOS_DATE);
    w32(h, crc);
    if zip64 {
        w32(h, 0xFFFF_FFFF);
        w32(h, 0xFFFF_FFFF);
    } else {
        w32(h, csize as u32);
        w32(h, usize_ as u32);
    }
    w16(h, name.len() as u16);
    let mut extra = Vec::new();
    if zip64 {
        w16(&mut extra, 1);
        w16(&mut extra, 16);
        w64(&mut extra, usize_);
        w64(&mut extra, csize);
    }
    w16(h, extra.len() as u16);
    h.extend_from_slice(name.as_bytes());
    h.extend_from_slice(&extra);
}
