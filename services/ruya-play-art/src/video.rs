//! Video slots (`trailer`, `preview`): container and codec allow-list from the headers only.
//!
//! Nothing is decoded and nothing is re-encoded. The two container readers are small and
//! hand-written (EBML for WebM, ISO-BMFF boxes for MP4); they read only the first MiB of a WebM
//! file and only the `ftyp` and `moov` boxes of an MP4 file, and every length is checked against
//! the bytes at hand before it is used. A vetted file is copied unchanged under a name that
//! comes from the detected container, never from the package.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use crate::{codes, fail, Fail, Slot};

const MIB: u64 = 1024 * 1024;
/// How much of a WebM file is read (Info and Tracks come before the first Cluster).
const WEBM_HEAD: usize = MIB as usize;
/// Largest `moov` box read (it holds the sample tables).
const MAX_MOOV: u64 = 8 * MIB;

struct Limits {
    max_bytes: u64,
    max_seconds: f64,
    max_w: u32,
    max_h: u32,
    max_fps: f64,
    max_bits_per_second: f64,
    audio: bool,
}

fn limits_for(slot: Slot) -> Limits {
    if slot == Slot::Trailer {
        Limits {
            max_bytes: 80 * MIB,
            max_seconds: 120.0,
            max_w: 1920,
            max_h: 1080,
            max_fps: 60.0,
            max_bits_per_second: 20_000_000.0,
            audio: true,
        }
    } else {
        Limits {
            max_bytes: 8 * MIB,
            max_seconds: 15.0,
            max_w: 1280,
            max_h: 720,
            max_fps: 30.0,
            max_bits_per_second: 6_000_000.0,
            audio: false,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Container {
    WebM,
    Mp4,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Video,
    Audio,
    Other,
}

struct Track {
    kind: Kind,
    codec: String,
    w: u32,
    h: u32,
    fps: Option<f64>,
}

struct Probe {
    duration: Option<f64>,
    tracks: Vec<Track>,
}

fn invalid<T>(what: &str) -> Result<T, Fail> {
    fail(codes::HEADER_INVALID, what.to_string())
}

pub(crate) fn vet_video(slot: Slot, path: &Path, out_dir: &Path) -> Result<Vec<PathBuf>, Fail> {
    let lim = limits_for(slot);
    let io = |e: std::io::Error| Fail {
        code: codes::VIDEO_IO,
        message: format!("{}: {e}", path.display()),
    };
    let meta = std::fs::symlink_metadata(path).map_err(io)?;
    if !meta.is_file() {
        return fail(codes::VIDEO_NOT_A_FILE, "not a regular file");
    }
    let size = meta.len();
    if size > lim.max_bytes {
        return fail(
            codes::VIDEO_FILE_TOO_LARGE,
            format!("{size} bytes, at most {}", lim.max_bytes),
        );
    }
    let mut file = File::open(path).map_err(io)?;
    let mut head = Vec::new();
    (&mut file)
        .take(WEBM_HEAD as u64)
        .read_to_end(&mut head)
        .map_err(io)?;

    let container = if head.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        Container::WebM
    } else if head.len() >= 12 && &head[4..8] == b"ftyp" {
        Container::Mp4
    } else {
        return fail(
            codes::CONTAINER_NOT_ALLOWED,
            "not a WebM or MP4 file (magic bytes)",
        );
    };
    let probe = match container {
        Container::WebM => probe_webm(&head)?,
        Container::Mp4 => probe_mp4(&mut file, size)?,
    };
    judge(container, &probe, &lim, size)?;

    let ext = if container == Container::WebM {
        "webm"
    } else {
        "mp4"
    };
    let tmp = out_dir.join(format!("{}.{ext}.part", slot.key()));
    std::fs::create_dir_all(out_dir).map_err(io)?;
    std::fs::copy(path, &tmp).map_err(io)?;
    let dest = out_dir.join(format!("{}.{ext}", slot.key()));
    std::fs::rename(&tmp, &dest).map_err(io)?;
    Ok(vec![dest])
}

fn judge(c: Container, p: &Probe, lim: &Limits, size: u64) -> Result<(), Fail> {
    if p.tracks.iter().any(|t| t.kind == Kind::Other) {
        return fail(
            codes::TRACK_NOT_ALLOWED,
            "only one video and at most one audio track are accepted",
        );
    }
    let videos: Vec<&Track> = p.tracks.iter().filter(|t| t.kind == Kind::Video).collect();
    let audios: Vec<&Track> = p.tracks.iter().filter(|t| t.kind == Kind::Audio).collect();
    if videos.is_empty() {
        return fail(codes::NO_VIDEO_TRACK, "no video track");
    }
    if videos.len() > 1 || audios.len() > 1 {
        return fail(
            codes::TRACK_NOT_ALLOWED,
            "only one video and at most one audio track are accepted",
        );
    }
    let v = videos[0];
    let (vok, aok): (&[&str], &str) = match c {
        Container::WebM => (&["V_VP9", "V_AV1"], "A_OPUS"),
        Container::Mp4 => (&["avc1", "avc3"], "mp4a"),
    };
    if !vok.contains(&v.codec.as_str()) {
        return fail(
            codes::CODEC_NOT_ALLOWED,
            format!("video codec {} is not on the allow-list", v.codec),
        );
    }
    if let Some(a) = audios.first() {
        if !lim.audio {
            return fail(codes::AUDIO_NOT_ALLOWED, "a preview has no audio track");
        }
        if a.codec != aok {
            return fail(
                codes::CODEC_NOT_ALLOWED,
                format!("audio codec {} is not on the allow-list", a.codec),
            );
        }
    }
    let secs = match p.duration {
        Some(d) if d.is_finite() && d > 0.0 => d,
        _ => return fail(codes::NO_DURATION, "no usable duration in the header"),
    };
    if secs > lim.max_seconds {
        return fail(
            codes::TOO_LONG,
            format!("{secs:.1} s, at most {} s", lim.max_seconds),
        );
    }
    if v.w == 0 || v.h == 0 {
        return invalid("video track without dimensions");
    }
    if v.w > lim.max_w || v.h > lim.max_h {
        return fail(
            codes::RESOLUTION_TOO_LARGE,
            format!("{}x{}, at most {}x{}", v.w, v.h, lim.max_w, lim.max_h),
        );
    }
    // The frame rate is checked when the header declares it.
    if let Some(fps) = v.fps {
        if fps > lim.max_fps + 0.5 {
            return fail(
                codes::FRAME_RATE_TOO_HIGH,
                format!("{fps:.1} fps, at most {}", lim.max_fps),
            );
        }
    }
    let bps = size as f64 * 8.0 / secs;
    if bps > lim.max_bits_per_second {
        return fail(
            codes::BITRATE_TOO_HIGH,
            format!(
                "{:.1} Mbit/s, at most {}",
                bps / 1e6,
                lim.max_bits_per_second / 1e6
            ),
        );
    }
    Ok(())
}

// ---------------------------------------------------------------- WebM (EBML)

const ID_EBML: u32 = 0x1A45_DFA3;
const ID_DOCTYPE: u32 = 0x4282;
const ID_SEGMENT: u32 = 0x1853_8067;
const ID_INFO: u32 = 0x1549_A966;
const ID_TIMESCALE: u32 = 0x2A_D7B1;
const ID_DURATION: u32 = 0x4489;
const ID_TRACKS: u32 = 0x1654_AE6B;
const ID_TRACK_ENTRY: u32 = 0xAE;
const ID_TRACK_TYPE: u32 = 0x83;
const ID_CODEC_ID: u32 = 0x86;
const ID_DEFAULT_DURATION: u32 = 0x23_E383;
const ID_VIDEO: u32 = 0xE0;
const ID_PIXEL_W: u32 = 0xB0;
const ID_PIXEL_H: u32 = 0xBA;
const ID_CLUSTER: u32 = 0x1F43_B675;

struct Elem<'a> {
    id: u32,
    data: &'a [u8],
    /// The declared size runs past the bytes at hand.
    cut: bool,
}

/// Next element at `*pos`, or None at the end. Err on a malformed header.
fn next_elem<'a>(buf: &'a [u8], pos: &mut usize) -> Result<Option<Elem<'a>>, Fail> {
    if *pos >= buf.len() {
        return Ok(None);
    }
    let b = buf[*pos];
    let idlen = b.leading_zeros() as usize + 1;
    if b == 0 || idlen > 4 || *pos + idlen > buf.len() {
        return invalid("bad EBML element id");
    }
    let id = buf[*pos..*pos + idlen]
        .iter()
        .fold(0u32, |a, x| (a << 8) | u32::from(*x));
    let sp = *pos + idlen;
    if sp >= buf.len() {
        return invalid("truncated EBML element");
    }
    let b = buf[sp];
    let slen = b.leading_zeros() as usize + 1;
    if b == 0 || slen > 8 || sp + slen > buf.len() {
        return invalid("bad EBML size");
    }
    let mut v = u64::from(b) & ((1u64 << (8 - slen)) - 1);
    let mut all_ones = v == (1u64 << (8 - slen)) - 1;
    for x in &buf[sp + 1..sp + slen] {
        v = (v << 8) | u64::from(*x);
        all_ones &= *x == 0xFF;
    }
    let start = sp + slen;
    let avail = (buf.len() - start) as u64;
    let (len, cut) = if all_ones {
        (avail, false) // unknown size: to the end
    } else if v > avail {
        (avail, true)
    } else {
        (v, false)
    };
    *pos = start + len as usize;
    Ok(Some(Elem {
        id,
        data: &buf[start..start + len as usize],
        cut,
    }))
}

fn uint(d: &[u8]) -> u64 {
    d.iter().take(8).fold(0, |a, x| (a << 8) | u64::from(*x))
}

fn float(d: &[u8]) -> Option<f64> {
    match d.len() {
        4 => Some(f64::from(f32::from_be_bytes(d.try_into().ok()?))),
        8 => Some(f64::from_be_bytes(d.try_into().ok()?)),
        _ => None,
    }
}

fn probe_webm(buf: &[u8]) -> Result<Probe, Fail> {
    let mut pos = 0;
    match next_elem(buf, &mut pos)? {
        Some(e) if e.id == ID_EBML && !e.cut => {
            let mut p = 0;
            let mut doctype = None;
            while let Some(c) = next_elem(e.data, &mut p)? {
                if c.id == ID_DOCTYPE {
                    doctype = Some(c.data);
                }
            }
            if doctype != Some(&b"webm"[..]) {
                return fail(codes::CONTAINER_NOT_ALLOWED, "EBML DocType is not webm");
            }
        }
        _ => return invalid("missing EBML header"),
    }
    let segment = loop {
        match next_elem(buf, &mut pos)? {
            Some(e) if e.id == ID_SEGMENT => break e,
            Some(_) => continue,
            None => return invalid("no Segment"),
        }
    };
    let mut probe = Probe {
        duration: None,
        tracks: Vec::new(),
    };
    let mut timescale = 1_000_000u64;
    let mut raw_duration = None;
    let mut have_tracks = false;
    let mut p = 0;
    while let Some(e) = next_elem(segment.data, &mut p)? {
        match e.id {
            ID_CLUSTER => break,
            ID_INFO | ID_TRACKS if e.cut => return invalid("header not within the first MiB"),
            ID_INFO => {
                let mut q = 0;
                while let Some(c) = next_elem(e.data, &mut q)? {
                    match c.id {
                        ID_TIMESCALE => timescale = uint(c.data),
                        ID_DURATION => raw_duration = float(c.data),
                        _ => {}
                    }
                }
            }
            ID_TRACKS => {
                have_tracks = true;
                let mut q = 0;
                while let Some(c) = next_elem(e.data, &mut q)? {
                    if c.id == ID_TRACK_ENTRY {
                        probe.tracks.push(webm_track(c.data)?);
                    }
                }
            }
            _ => {}
        }
    }
    if !have_tracks {
        return invalid("no Tracks before the first Cluster");
    }
    probe.duration = raw_duration.map(|d| d * timescale as f64 / 1e9);
    Ok(probe)
}

fn webm_track(buf: &[u8]) -> Result<Track, Fail> {
    let mut t = Track {
        kind: Kind::Other,
        codec: String::new(),
        w: 0,
        h: 0,
        fps: None,
    };
    let mut p = 0;
    while let Some(e) = next_elem(buf, &mut p)? {
        match e.id {
            ID_TRACK_TYPE => {
                t.kind = match uint(e.data) {
                    1 => Kind::Video,
                    2 => Kind::Audio,
                    _ => Kind::Other,
                }
            }
            ID_CODEC_ID => t.codec = String::from_utf8_lossy(e.data).into_owned(),
            ID_DEFAULT_DURATION => {
                let ns = uint(e.data);
                if ns > 0 {
                    t.fps = Some(1e9 / ns as f64);
                }
            }
            ID_VIDEO => {
                let mut q = 0;
                while let Some(c) = next_elem(e.data, &mut q)? {
                    match c.id {
                        ID_PIXEL_W => t.w = uint(c.data).min(u64::from(u32::MAX)) as u32,
                        ID_PIXEL_H => t.h = uint(c.data).min(u64::from(u32::MAX)) as u32,
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    Ok(t)
}

// ---------------------------------------------------------------- MP4 (ISO-BMFF)

/// The boxes directly inside `buf`: (type, payload).
type BoxRef<'a> = ([u8; 4], &'a [u8]);

fn boxes(buf: &[u8]) -> Result<Vec<BoxRef<'_>>, Fail> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < buf.len() {
        if buf.len() - pos < 8 {
            return invalid("truncated box header");
        }
        let size =
            u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]) as usize;
        let typ = [buf[pos + 4], buf[pos + 5], buf[pos + 6], buf[pos + 7]];
        let (hdr, total) = match size {
            0 => (8, buf.len() - pos),
            1 => {
                if buf.len() - pos < 16 {
                    return invalid("truncated box header");
                }
                let mut b = [0u8; 8];
                b.copy_from_slice(&buf[pos + 8..pos + 16]);
                (
                    16,
                    usize::try_from(u64::from_be_bytes(b)).unwrap_or(usize::MAX),
                )
            }
            n => (8, n),
        };
        if total < hdr || total > buf.len() - pos {
            return invalid("box size outside its parent");
        }
        out.push((typ, &buf[pos + hdr..pos + total]));
        pos += total;
    }
    Ok(out)
}

fn be32(d: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(d.get(at..at + 4)?.try_into().ok()?))
}

fn be64(d: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(d.get(at..at + 8)?.try_into().ok()?))
}

/// (timescale, duration) of an `mvhd` or `mdhd` payload.
fn time_header(d: &[u8]) -> Option<(u32, u64)> {
    if *d.first()? == 1 {
        Some((be32(d, 20)?, be64(d, 24)?))
    } else {
        Some((be32(d, 12)?, u64::from(be32(d, 16)?)))
    }
}

fn probe_mp4(file: &mut File, len: u64) -> Result<Probe, Fail> {
    let io = |e: std::io::Error| Fail {
        code: codes::VIDEO_IO,
        message: e.to_string(),
    };
    let mut pos = 0u64;
    let mut moov: Option<Vec<u8>> = None;
    let mut first = true;
    while pos + 8 <= len {
        file.seek(SeekFrom::Start(pos)).map_err(io)?;
        let mut h = [0u8; 16];
        let n = (len - pos).min(16) as usize;
        file.read_exact(&mut h[..n]).map_err(io)?;
        let size32 = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
        let typ = [h[4], h[5], h[6], h[7]];
        let (hdr, total) = match size32 {
            0 => (8, len - pos),
            1 => {
                if n < 16 {
                    return invalid("truncated box header");
                }
                let mut b = [0u8; 8];
                b.copy_from_slice(&h[8..16]);
                (16, u64::from_be_bytes(b))
            }
            s => (8, s),
        };
        if total < hdr || total > len - pos {
            return invalid("top-level box outside the file");
        }
        if first && &typ != b"ftyp" {
            return fail(codes::CONTAINER_NOT_ALLOWED, "ftyp is not the first box");
        }
        first = false;
        if &typ == b"moov" {
            if total - hdr > MAX_MOOV {
                return invalid("moov box too large");
            }
            let mut v = vec![0u8; (total - hdr) as usize];
            file.seek(SeekFrom::Start(pos + hdr)).map_err(io)?;
            file.read_exact(&mut v).map_err(io)?;
            moov = Some(v);
            break;
        }
        pos += total;
    }
    let moov = match moov {
        Some(m) => m,
        None => return invalid("no moov box"),
    };
    let mut probe = Probe {
        duration: None,
        tracks: Vec::new(),
    };
    for (typ, d) in boxes(&moov)? {
        match &typ {
            b"mvhd" => {
                if let Some((ts, dur)) = time_header(d) {
                    if ts > 0 {
                        probe.duration = Some(dur as f64 / f64::from(ts));
                    }
                }
            }
            b"trak" => probe.tracks.push(mp4_track(d)?),
            _ => {}
        }
    }
    Ok(probe)
}

fn mp4_track(trak: &[u8]) -> Result<Track, Fail> {
    let mut t = Track {
        kind: Kind::Other,
        codec: String::new(),
        w: 0,
        h: 0,
        fps: None,
    };
    let mut media: Option<(u32, u64)> = None;
    let mut samples: Option<u64> = None;
    for (typ, d) in boxes(trak)? {
        match &typ {
            b"tkhd" if d.len() >= 8 => {
                // width and height are the last two 16.16 fixed-point fields
                t.w = be32(d, d.len() - 8).unwrap_or(0) >> 16;
                t.h = be32(d, d.len() - 4).unwrap_or(0) >> 16;
            }
            b"mdia" => {
                for (mt, md) in boxes(d)? {
                    match &mt {
                        b"mdhd" => media = time_header(md),
                        b"hdlr" => {
                            t.kind = match md.get(8..12) {
                                Some(b"vide") => Kind::Video,
                                Some(b"soun") => Kind::Audio,
                                _ => Kind::Other,
                            }
                        }
                        b"minf" => {
                            for (ft, fd) in boxes(md)? {
                                if &ft != b"stbl" {
                                    continue;
                                }
                                for (st, sd) in boxes(fd)? {
                                    match &st {
                                        b"stsd" => {
                                            if let Some(c) = sd.get(12..16) {
                                                t.codec = String::from_utf8_lossy(c).into_owned();
                                            }
                                        }
                                        b"stts" => samples = stts_samples(sd),
                                        _ => {}
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    if let (Some((ts, dur)), Some(n)) = (media, samples) {
        if ts > 0 && dur > 0 {
            t.fps = Some(n as f64 / (dur as f64 / f64::from(ts)));
        }
    }
    Ok(t)
}

fn stts_samples(d: &[u8]) -> Option<u64> {
    let entries = be32(d, 4)? as usize;
    let mut total = 0u64;
    for i in 0..entries.min(d.len().saturating_sub(8) / 8) {
        total += u64::from(be32(d, 8 + i * 8)?);
    }
    Some(total)
}
