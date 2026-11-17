//! The `.play.zip` reader (05 §2, §4.3). It reads the central directory only, checks every local
//! header against it, and refuses what a second reader could interpret differently: encryption,
//! links and special files, duplicate names, data before, between or after the entries, an entry
//! that expands too much, and content that does not match its declared size.
//!
//! The reader is written for this format rather than taken from a general zip crate, so that each
//! rule above is a line here and a test in `tests/hostile.rs`.

use crate::limits::{expansion_exceeds, MAX_ZIP_ENTRIES};
use crate::problem::{codes, Problem, Problems};
use crate::source::{Entry, EntryKind, ReadFault, Source};
use flate2::read::DeflateDecoder;
use flate2::Crc;
use std::collections::{HashMap, HashSet};
use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Mutex, MutexGuard};

const EOCD_SIG: u32 = 0x0605_4b50;
const EOCD64_SIG: u32 = 0x0606_4b50;
const LOCATOR64_SIG: u32 = 0x0706_4b50;
const CD_SIG: u32 = 0x0201_4b50;
const LOCAL_SIG: u32 = 0x0403_4b50;
const EOCD_LEN: u64 = 22;
const LOCATOR64_LEN: u64 = 20;
const EOCD64_FIXED: u64 = 56;
const LOCAL_FIXED: u64 = 30;
/// A central directory bigger than this is refused before it is read (256 MiB).
const MAX_CD_BYTES: u64 = 256 * 1024 * 1024;
/// Sizes a data descriptor after an entry's data can have (with or without its signature, 32 or 64 bit).
const DESCRIPTOR_LENGTHS: [u64; 4] = [12, 16, 20, 24];

#[derive(Debug, Clone)]
struct ZipEntry {
    raw_name: Vec<u8>,
    name: String,
    kind: EntryKind,
    size: u64,
    compressed: u64,
    method: u16,
    crc: u32,
    flags: u16,
    offset: u64,
    data_start: u64,
}

/// A `.play.zip` over any seekable reader.
pub struct ZipSource<R: Read + Seek> {
    reader: Mutex<R>,
    entries: Vec<ZipEntry>,
    by_name: HashMap<String, usize>,
}

fn le16(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}
fn le32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}
fn le64(b: &[u8], at: usize) -> u64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[at..at + 8]);
    u64::from_le_bytes(a)
}

fn malformed(what: &str) -> Vec<Problem> {
    vec![Problem::new(
        codes::ZIP_MALFORMED,
        "",
        format!("The zip file is damaged ({what})."),
    )]
}

fn read_at<R: Read + Seek>(r: &mut R, pos: u64, n: usize) -> io::Result<Vec<u8>> {
    r.seek(SeekFrom::Start(pos))?;
    let mut buf = vec![0u8; n];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

/// Sizes and offset from a ZIP64 extra field, for the fields whose 32-bit value is saturated.
fn zip64_fields(
    extra: &[u8],
    need_usize: bool,
    need_csize: bool,
    need_off: bool,
) -> Result<[Option<u64>; 3], ()> {
    let mut out = [None, None, None];
    let mut seen64 = false;
    let mut i = 0;
    while i < extra.len() {
        if extra.len() - i < 4 {
            return Err(());
        }
        let id = le16(extra, i);
        let len = le16(extra, i + 2) as usize;
        i += 4;
        if extra.len() - i < len {
            return Err(());
        }
        if id == 1 {
            if seen64 {
                return Err(());
            }
            seen64 = true;
            let mut data = &extra[i..i + len];
            let mut take = |want: bool| -> Result<Option<u64>, ()> {
                if !want {
                    return Ok(None);
                }
                if data.len() < 8 {
                    return Err(());
                }
                let v = le64(data, 0);
                data = &data[8..];
                Ok(Some(v))
            };
            out[0] = take(need_usize)?;
            out[1] = take(need_csize)?;
            out[2] = take(need_off)?;
        }
        i += len;
    }
    Ok(out)
}

fn classify(made_by: u16, external: u32, dir_name: bool) -> Result<EntryKind, ()> {
    let host = (made_by >> 8) as u8;
    if host == 3 {
        let mode = external >> 16;
        return match mode & 0o170000 {
            0 | 0o100000 => {
                if dir_name && mode & 0o170000 != 0 {
                    Err(())
                } else if dir_name {
                    Ok(EntryKind::Dir)
                } else {
                    Ok(EntryKind::File)
                }
            }
            0o040000 => Ok(EntryKind::Dir),
            0o120000 => Ok(EntryKind::Symlink),
            0o060000 | 0o020000 => Ok(EntryKind::Device),
            _ => Ok(EntryKind::Other),
        };
    }
    if host == 10 && external & 0x400 != 0 {
        return Ok(EntryKind::Symlink);
    }
    Ok(if dir_name || external & 0x10 != 0 {
        EntryKind::Dir
    } else {
        EntryKind::File
    })
}

impl<R: Read + Seek> ZipSource<R> {
    /// Read the central directory of `reader` and check the container. Returns every structural
    /// problem found; `Ok` means the entry list can be trusted.
    pub fn new(mut reader: R) -> Result<Self, Vec<Problem>> {
        let len = reader
            .seek(SeekFrom::End(0))
            .map_err(|_| malformed("cannot measure it"))?;
        if len < EOCD_LEN {
            return Err(vec![Problem::new(
                codes::ZIP_NOT_A_ZIP,
                "",
                "This is not a zip file.",
            )]);
        }
        let tail = read_at(&mut reader, len - EOCD_LEN, EOCD_LEN as usize)
            .map_err(|_| malformed("cannot read the end"))?;
        if le32(&tail, 0) != EOCD_SIG {
            // Look for a record further back to tell "a comment or junk after the archive" from "not a zip".
            let window = len.min(EOCD_LEN + 65_535 + 16);
            let buf = read_at(&mut reader, len - window, window as usize)
                .map_err(|_| malformed("cannot read the end"))?;
            let found = buf.windows(4).any(|w| w == EOCD_SIG.to_le_bytes());
            return Err(vec![if found {
                Problem::new(
                    codes::ZIP_TRAILING_DATA,
                    "",
                    "The zip file has a comment or other data after its end; save it again without one.",
                )
            } else {
                Problem::new(codes::ZIP_NOT_A_ZIP, "", "This is not a zip file.")
            }]);
        }
        let eocd_pos = len - EOCD_LEN;
        let (disk, cd_disk) = (le16(&tail, 4), le16(&tail, 6));
        let mut count = le16(&tail, 10) as u64;
        let mut cd_size = le32(&tail, 12) as u64;
        let mut cd_off = le32(&tail, 16) as u64;
        let mut cd_end_limit = eocd_pos;
        if le16(&tail, 20) != 0 {
            return Err(vec![Problem::new(
                codes::ZIP_TRAILING_DATA,
                "",
                "The zip file has a comment; save it again without one.",
            )]);
        }
        let saturated =
            le16(&tail, 10) == 0xFFFF || le32(&tail, 12) == u32::MAX || le32(&tail, 16) == u32::MAX;
        let has_locator = eocd_pos >= LOCATOR64_LEN && {
            let loc = read_at(
                &mut reader,
                eocd_pos - LOCATOR64_LEN,
                LOCATOR64_LEN as usize,
            )
            .map_err(|_| malformed("cannot read the end"))?;
            le32(&loc, 0) == LOCATOR64_SIG
        };
        let (mut disk, mut cd_disk) = (disk as u32, cd_disk as u32);
        if has_locator || saturated {
            if !has_locator {
                return Err(malformed("a ZIP64 value without its locator"));
            }
            let loc = read_at(
                &mut reader,
                eocd_pos - LOCATOR64_LEN,
                LOCATOR64_LEN as usize,
            )
            .map_err(|_| malformed("cannot read the end"))?;
            let (loc_disk, rec_off, total_disks) = (le32(&loc, 4), le64(&loc, 8), le32(&loc, 16));
            if loc_disk != 0 || total_disks != 1 {
                return Err(vec![Problem::new(
                    codes::ZIP_MULTI_DISK,
                    "",
                    "Zip files split over several parts are not accepted.",
                )]);
            }
            let locator_pos = eocd_pos - LOCATOR64_LEN;
            if rec_off
                .checked_add(EOCD64_FIXED)
                .map_or(true, |e| e > locator_pos)
            {
                return Err(malformed("the ZIP64 record is out of place"));
            }
            let rec = read_at(&mut reader, rec_off, EOCD64_FIXED as usize)
                .map_err(|_| malformed("cannot read the ZIP64 record"))?;
            if le32(&rec, 0) != EOCD64_SIG {
                return Err(malformed("the ZIP64 record is missing"));
            }
            let rest = le64(&rec, 4);
            if rec_off.checked_add(12).and_then(|x| x.checked_add(rest)) != Some(locator_pos) {
                return Err(malformed(
                    "there is data between the ZIP64 record and its locator",
                ));
            }
            disk = le32(&rec, 16);
            cd_disk = le32(&rec, 20);
            let (n_here, n_total) = (le64(&rec, 24), le64(&rec, 32));
            if n_here != n_total {
                return Err(vec![Problem::new(
                    codes::ZIP_MULTI_DISK,
                    "",
                    "Zip files split over several parts are not accepted.",
                )]);
            }
            count = n_total;
            cd_size = le64(&rec, 40);
            cd_off = le64(&rec, 48);
            cd_end_limit = rec_off;
        }
        if disk != 0 || cd_disk != 0 {
            return Err(vec![Problem::new(
                codes::ZIP_MULTI_DISK,
                "",
                "Zip files split over several parts are not accepted.",
            )]);
        }
        if count > MAX_ZIP_ENTRIES as u64 {
            return Err(vec![Problem::new(
                codes::ZIP_TOO_MANY_ENTRIES,
                "",
                format!("The zip file has {count} entries; at most {MAX_ZIP_ENTRIES}."),
            )]);
        }
        if cd_off.checked_add(cd_size) != Some(cd_end_limit) {
            return Err(malformed(
                "the central directory does not end where the archive's end record begins",
            ));
        }
        if cd_size > MAX_CD_BYTES {
            return Err(malformed("the central directory is too large"));
        }
        let cd = read_at(&mut reader, cd_off, cd_size as usize)
            .map_err(|_| malformed("cannot read the central directory"))?;

        let mut problems = Problems::new();
        let mut entries: Vec<ZipEntry> = Vec::with_capacity(count as usize);
        let mut pos = 0usize;
        for _ in 0..count {
            if cd.len() - pos < 46 || le32(&cd, pos) != CD_SIG {
                return Err(malformed("the central directory is cut short"));
            }
            let made_by = le16(&cd, pos + 4);
            let flags = le16(&cd, pos + 8);
            let method = le16(&cd, pos + 10);
            let crc = le32(&cd, pos + 16);
            let (c32, u32v) = (le32(&cd, pos + 20), le32(&cd, pos + 24));
            let (nlen, elen, clen) = (
                le16(&cd, pos + 28) as usize,
                le16(&cd, pos + 30) as usize,
                le16(&cd, pos + 32) as usize,
            );
            let disk_start = le16(&cd, pos + 34);
            let external = le32(&cd, pos + 38);
            let off32 = le32(&cd, pos + 42);
            let next = pos + 46 + nlen + elen + clen;
            if next > cd.len() {
                return Err(malformed("the central directory is cut short"));
            }
            let raw_name = cd[pos + 46..pos + 46 + nlen].to_vec();
            let extra = &cd[pos + 46 + nlen..pos + 46 + nlen + elen];
            pos = next;

            let lossy = String::from_utf8_lossy(&raw_name).into_owned();
            let name = match String::from_utf8(raw_name.clone()) {
                Ok(n) => n,
                Err(_) => {
                    problems.add(
                        codes::PATH_INVALID_UTF8,
                        lossy,
                        "The name is not valid UTF-8; store names as UTF-8.",
                    );
                    continue;
                }
            };
            let (mut size, mut compressed, mut offset) = (u32v as u64, c32 as u64, off32 as u64);
            let sat = (u32v == u32::MAX, c32 == u32::MAX, off32 == u32::MAX);
            match zip64_fields(extra, sat.0, sat.1, sat.2) {
                Ok(f) => {
                    if sat.0 {
                        size = f[0].unwrap_or(size);
                    }
                    if sat.1 {
                        compressed = f[1].unwrap_or(compressed);
                    }
                    if sat.2 {
                        offset = f[2].unwrap_or(offset);
                    }
                }
                Err(()) => {
                    problems.add(
                        codes::ZIP_MALFORMED,
                        name,
                        "The entry's extra data is damaged.",
                    );
                    continue;
                }
            }
            if flags & (0x0001 | 0x0040 | 0x2000) != 0 || method == 99 {
                problems.add(
                    codes::ZIP_ENCRYPTED,
                    name,
                    "The entry is encrypted; packages are never encrypted.",
                );
                continue;
            }
            if method != 0 && method != 8 {
                problems.add(
                    codes::ZIP_METHOD,
                    name,
                    format!("Compression method {method} is not accepted; use stored or deflate."),
                );
                continue;
            }
            if disk_start != 0 {
                problems.add(
                    codes::ZIP_MULTI_DISK,
                    name,
                    "The entry is on another disk of a split archive.",
                );
                continue;
            }
            let dir_name = name.ends_with('/');
            let kind = match classify(made_by, external, dir_name) {
                Ok(k) => k,
                Err(()) => {
                    problems.add(
                        codes::ZIP_MALFORMED,
                        name,
                        "The entry's name and type disagree.",
                    );
                    continue;
                }
            };
            if method == 0 && compressed != size {
                problems.add(
                    codes::ZIP_MALFORMED,
                    name,
                    "A stored entry has different compressed and real sizes.",
                );
                continue;
            }
            if kind == EntryKind::Dir && (size != 0 || compressed != 0) {
                problems.add(codes::ZIP_MALFORMED, name, "A directory entry has content.");
                continue;
            }
            if expansion_exceeds(size, compressed) {
                problems.add(
                    codes::ZIP_RATIO,
                    name,
                    "The entry expands far more than any real file does (a zip bomb); store the file uncompressed.",
                );
                continue;
            }
            entries.push(ZipEntry {
                raw_name,
                name,
                kind,
                size,
                compressed,
                method,
                crc,
                flags,
                offset,
                data_start: 0,
            });
        }
        if pos != cd.len() {
            return Err(malformed(
                "there is data after the last central directory entry",
            ));
        }

        // Names: no duplicates, also not between "x" and "x/".
        let mut seen: HashSet<&str> = HashSet::new();
        for e in &entries {
            if !seen.insert(e.name.trim_end_matches('/')) {
                problems.add(
                    codes::ZIP_DUPLICATE_ENTRY,
                    e.name.trim_end_matches('/'),
                    "The zip file has two entries with this name.",
                );
            }
        }
        // A second name for the same stored content is a hard link.
        let mut offsets: HashSet<u64> = HashSet::new();
        for e in entries.iter_mut() {
            if !offsets.insert(e.offset) {
                e.kind = EntryKind::HardLink;
            }
        }
        if !problems.is_empty() {
            return Err(problems.finish());
        }

        // Local headers must agree with the directory, and entries must tile the file exactly.
        let mut order: Vec<usize> = (0..entries.len())
            .filter(|&i| entries[i].kind != EntryKind::HardLink)
            .collect();
        order.sort_by_key(|&i| entries[i].offset);
        let mut expected = 0u64;
        let mut prev_descriptor = false;
        for (n, &i) in order.iter().enumerate() {
            let off = entries[i].offset;
            let gap_ok = |want: u64, got: u64, desc: bool| {
                got == want || (desc && DESCRIPTOR_LENGTHS.contains(&(got - want)) && got > want)
            };
            if n == 0 && off != 0 {
                problems.add(
                    codes::ZIP_LEADING_DATA,
                    "",
                    "There is data before the first entry; a zip file starts with its first entry.",
                );
                break;
            }
            if off < expected {
                problems.add(
                    codes::ZIP_OVERLAP,
                    entries[i].name.clone(),
                    "Entries overlap in the file.",
                );
                break;
            }
            if !gap_ok(expected, off, prev_descriptor) {
                problems.add(
                    codes::ZIP_GAP,
                    entries[i].name.clone(),
                    "There is unaccounted data between entries.",
                );
                break;
            }
            let hdr = match read_at(&mut reader, off, LOCAL_FIXED as usize) {
                Ok(h) if le32(&h, 0) == LOCAL_SIG => h,
                _ => {
                    problems.add(
                        codes::ZIP_LOCAL_MISMATCH,
                        entries[i].name.clone(),
                        "The entry's local header is missing or damaged.",
                    );
                    break;
                }
            };
            let (nlen, elen) = (le16(&hdr, 26) as u64, le16(&hdr, 28) as u64);
            let body = match read_at(&mut reader, off + LOCAL_FIXED, (nlen + elen) as usize) {
                Ok(b) => b,
                Err(_) => {
                    problems.add(
                        codes::ZIP_LOCAL_MISMATCH,
                        entries[i].name.clone(),
                        "The entry's local header is cut short.",
                    );
                    break;
                }
            };
            let e = &entries[i];
            let descriptor = e.flags & 0x0008 != 0;
            let mut same = le16(&hdr, 6) == e.flags
                && le16(&hdr, 8) == e.method
                && body[..nlen as usize] == e.raw_name[..];
            if same && !descriptor {
                let (lc, lu) = (le32(&hdr, 18), le32(&hdr, 22));
                let (mut csize, mut usize_) = (lc as u64, lu as u64);
                if lc == u32::MAX || lu == u32::MAX {
                    match zip64_fields(
                        &body[nlen as usize..],
                        lu == u32::MAX,
                        lc == u32::MAX,
                        false,
                    ) {
                        Ok(f) => {
                            if lu == u32::MAX {
                                usize_ = f[0].unwrap_or(usize_);
                            }
                            if lc == u32::MAX {
                                csize = f[1].unwrap_or(csize);
                            }
                        }
                        Err(()) => same = false,
                    }
                }
                same = same && le32(&hdr, 14) == e.crc && csize == e.compressed && usize_ == e.size;
            }
            if !same {
                problems.add(
                    codes::ZIP_LOCAL_MISMATCH,
                    entries[i].name.clone(),
                    "The entry's local header disagrees with the central directory.",
                );
                break;
            }
            let data_start = off + LOCAL_FIXED + nlen + elen;
            let data_end = match data_start.checked_add(e.compressed) {
                Some(d) if d <= cd_off => d,
                _ => {
                    problems.add(
                        codes::ZIP_MALFORMED,
                        entries[i].name.clone(),
                        "The entry's data runs past the central directory.",
                    );
                    break;
                }
            };
            if descriptor {
                let room = len.saturating_sub(data_end).min(24) as usize;
                let ok = read_at(&mut reader, data_end, room).is_ok_and(|b| {
                    descriptor_matches(&b, entries[i].crc, entries[i].compressed, entries[i].size)
                });
                if !ok {
                    problems.add(
                        codes::ZIP_LOCAL_MISMATCH,
                        entries[i].name.clone(),
                        "The entry's data descriptor disagrees with the central directory.",
                    );
                    break;
                }
            }
            entries[i].data_start = data_start;
            expected = data_end;
            prev_descriptor = descriptor;
        }
        if problems.is_empty() && !gap_to_cd_ok(expected, cd_off, prev_descriptor) {
            problems.add(
                codes::ZIP_GAP,
                "",
                "There is unaccounted data between the last entry and the central directory.",
            );
        }
        if !problems.is_empty() {
            return Err(problems.finish());
        }
        // Hard links share their target's data.
        let starts: HashMap<u64, u64> = entries
            .iter()
            .filter(|e| e.kind != EntryKind::HardLink)
            .map(|e| (e.offset, e.data_start))
            .collect();
        for e in entries.iter_mut() {
            if e.kind == EntryKind::HardLink {
                e.data_start = starts.get(&e.offset).copied().unwrap_or(0);
            }
        }

        unwrap_single_folder(&mut entries);
        let by_name = entries
            .iter()
            .enumerate()
            .map(|(i, e)| (e.name.clone(), i))
            .collect();
        Ok(ZipSource {
            reader: Mutex::new(reader),
            entries,
            by_name,
        })
    }
}

/// The data descriptor after an entry's data (with or without its signature, 32 or 64 bit sizes)
/// gives the CRC and sizes the central directory gives.
fn descriptor_matches(buf: &[u8], crc: u32, csize: u64, size: u64) -> bool {
    let b = if buf.len() >= 4 && le32(buf, 0) == 0x0807_4b50 {
        &buf[4..]
    } else {
        buf
    };
    let ok32 = b.len() >= 12
        && le32(b, 0) == crc
        && le32(b, 4) as u64 == csize
        && le32(b, 8) as u64 == size;
    let ok64 = b.len() >= 20 && le32(b, 0) == crc && le64(b, 4) == csize && le64(b, 12) == size;
    ok32 || ok64
}

fn gap_to_cd_ok(expected: u64, cd_off: u64, descriptor: bool) -> bool {
    cd_off == expected
        || (descriptor && cd_off > expected && DESCRIPTOR_LENGTHS.contains(&(cd_off - expected)))
}

/// A zip made by zipping a folder has one top-level folder around `play.json` (05 §2): drop it.
fn unwrap_single_folder(entries: &mut Vec<ZipEntry>) {
    if entries.iter().any(|e| e.name == "play.json") {
        return;
    }
    let Some(top) = entries
        .iter()
        .find_map(|e| e.name.split_once('/').map(|(t, _)| t.to_string()))
    else {
        return;
    };
    if crate::path::check_path(&top).is_err() {
        return;
    }
    let prefix = format!("{top}/");
    if !entries.iter().all(|e| e.name.starts_with(&prefix))
        || !entries
            .iter()
            .any(|e| e.name == format!("{prefix}play.json"))
    {
        return;
    }
    entries.retain(|e| e.name != prefix);
    for e in entries.iter_mut() {
        e.name = e.name[prefix.len()..].to_string();
    }
}

struct Limited<'a, R> {
    guard: MutexGuard<'a, R>,
    left: u64,
}

impl<R: Read> Read for Limited<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.left == 0 || buf.is_empty() {
            return Ok(0);
        }
        let n = (buf.len() as u64).min(self.left) as usize;
        let got = self.guard.read(&mut buf[..n])?;
        self.left -= got as u64;
        Ok(got)
    }
}

/// Enforces the declared size and CRC while the content is read.
struct Checked<'a> {
    inner: Box<dyn Read + 'a>,
    path: String,
    declared: u64,
    seen: u64,
    crc: Crc,
    expected_crc: u32,
    done: bool,
}

impl Read for Checked<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.done || buf.is_empty() {
            return Ok(0);
        }
        let lies = |path: &str| {
            ReadFault::into_io(Problem::new(
                codes::ZIP_DECLARED_SIZE_LIES,
                path,
                "The entry's real size is not the size the zip file declares for it.",
            ))
        };
        // Ask for one byte more than is left, so extra content is noticed.
        let want = (buf.len() as u64).min((self.declared - self.seen).saturating_add(1)) as usize;
        let n = match self.inner.read(&mut buf[..want]) {
            Ok(n) => n,
            Err(e)
                if e.kind() == io::ErrorKind::InvalidInput
                    || e.kind() == io::ErrorKind::InvalidData
                    || e.kind() == io::ErrorKind::UnexpectedEof =>
            {
                return Err(ReadFault::into_io(Problem::new(
                    codes::ZIP_MALFORMED,
                    self.path.clone(),
                    "The entry's compressed data is damaged.",
                )));
            }
            Err(e) => return Err(e),
        };
        if n == 0 {
            self.done = true;
            if self.seen != self.declared {
                return Err(lies(&self.path));
            }
            if self.crc.sum() != self.expected_crc {
                return Err(ReadFault::into_io(Problem::new(
                    codes::ZIP_CRC_MISMATCH,
                    self.path.clone(),
                    "The entry's content does not match its checksum.",
                )));
            }
            return Ok(0);
        }
        self.seen += n as u64;
        if self.seen > self.declared {
            self.done = true;
            return Err(lies(&self.path));
        }
        self.crc.update(&buf[..n]);
        Ok(n)
    }
}

impl<R: Read + Seek> Source for ZipSource<R> {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        Ok(self
            .entries
            .iter()
            .map(|e| Entry {
                path: e.name.trim_end_matches('/').to_string(),
                kind: e.kind,
                size: e.size,
            })
            .collect())
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        let e = self
            .by_name
            .get(path)
            .map(|&i| &self.entries[i])
            .filter(|e| e.kind == EntryKind::File)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no such file in the zip"))?;
        let mut guard = self
            .reader
            .lock()
            .map_err(|_| io::Error::other("zip reader poisoned"))?;
        guard.seek(SeekFrom::Start(e.data_start))?;
        let limited = Limited {
            guard,
            left: e.compressed,
        };
        let inner: Box<dyn Read + '_> = if e.method == 8 {
            Box::new(DeflateDecoder::new(limited))
        } else {
            Box::new(limited)
        };
        Ok(Box::new(Checked {
            inner,
            path: path.to_string(),
            declared: e.size,
            seen: 0,
            crc: Crc::new(),
            expected_crc: e.crc,
            done: false,
        }))
    }
}
