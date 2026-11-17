//! Video allow-list: minimal EBML and ISO-BMFF headers, no frames.

mod common;

use common::*;
use ruya_play_art::{codes, Outcome, Slot};
use tempfile::tempdir;

// ------------------------------------------------------------------ WebM builder

fn elem(id: &[u8], data: &[u8]) -> Vec<u8> {
    let mut v = id.to_vec();
    v.push(0x01); // 8-byte size
    v.extend_from_slice(&(data.len() as u64).to_be_bytes()[1..]);
    v.extend_from_slice(data);
    v
}

struct WTrack {
    kind: u8,
    codec: &'static str,
    w: u32,
    h: u32,
    fps: Option<u32>,
    enc: bool,
}

fn vtrack(codec: &'static str, w: u32, h: u32, fps: u32) -> WTrack {
    WTrack {
        kind: 1,
        codec,
        w,
        h,
        fps: Some(fps),
        enc: false,
    }
}

fn atrack(codec: &'static str) -> WTrack {
    WTrack {
        kind: 2,
        codec,
        w: 0,
        h: 0,
        fps: None,
        enc: false,
    }
}

fn webm_doc(doctype: &str, seconds: f64, tracks: &[WTrack]) -> Vec<u8> {
    let mut v = elem(
        &[0x1A, 0x45, 0xDF, 0xA3],
        &elem(&[0x42, 0x82], doctype.as_bytes()),
    );
    let mut info = elem(&[0x2A, 0xD7, 0xB1], &1_000_000u32.to_be_bytes());
    info.extend(elem(&[0x44, 0x89], &(seconds * 1000.0).to_be_bytes()));
    let mut tr = Vec::new();
    for t in tracks {
        let mut e = elem(&[0x83], &[t.kind]);
        e.extend(elem(&[0x86], t.codec.as_bytes()));
        if let Some(fps) = t.fps {
            e.extend(elem(
                &[0x23, 0xE3, 0x83],
                &(1_000_000_000u64 / u64::from(fps)).to_be_bytes(),
            ));
        }
        if t.enc {
            e.extend(elem(&[0x6D, 0x80], &elem(&[0x62, 0x40], &[])));
        }
        if t.kind == 1 {
            let mut vid = elem(&[0xB0], &t.w.to_be_bytes());
            vid.extend(elem(&[0xBA], &t.h.to_be_bytes()));
            e.extend(elem(&[0xE0], &vid));
        }
        tr.extend(elem(&[0xAE], &e));
    }
    let mut seg = elem(&[0x15, 0x49, 0xA9, 0x66], &info);
    seg.extend(elem(&[0x16, 0x54, 0xAE, 0x6B], &tr));
    seg.extend(elem(&[0x1F, 0x43, 0xB6, 0x75], &[0u8; 16])); // a Cluster
    v.extend(elem(&[0x18, 0x53, 0x80, 0x67], &seg));
    v
}

fn webm(seconds: f64, tracks: &[WTrack]) -> Vec<u8> {
    webm_doc("webm", seconds, tracks)
}

// ------------------------------------------------------------------ MP4 builder

fn bx(typ: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut v = ((data.len() + 8) as u32).to_be_bytes().to_vec();
    v.extend_from_slice(typ);
    v.extend_from_slice(data);
    v
}

struct MTrack {
    handler: &'static [u8; 4],
    fourcc: &'static [u8; 4],
    w: u32,
    h: u32,
    fps: u32,
    /// a second sample entry in the stsd
    extra: Option<&'static [u8; 4]>,
}

fn mv(fourcc: &'static [u8; 4], w: u32, h: u32, fps: u32) -> MTrack {
    MTrack {
        handler: b"vide",
        fourcc,
        w,
        h,
        fps,
        extra: None,
    }
}

fn ma(fourcc: &'static [u8; 4]) -> MTrack {
    MTrack {
        handler: b"soun",
        fourcc,
        w: 0,
        h: 0,
        fps: 0,
        extra: None,
    }
}

fn mp4_trak(t: &MTrack, seconds: u32) -> Vec<u8> {
    let ts = 1000u32;
    let mut tkhd = vec![0u8; 4 + 4 + 4 + 4 + 4 + 4 + 8 + 2 + 2 + 2 + 2 + 36]; // version 0 up to the matrix
    tkhd.extend_from_slice(&(t.w << 16).to_be_bytes());
    tkhd.extend_from_slice(&(t.h << 16).to_be_bytes());
    let mut mdhd = vec![0u8; 12];
    mdhd.extend_from_slice(&ts.to_be_bytes());
    mdhd.extend_from_slice(&(seconds * ts).to_be_bytes());
    let mut hdlr = vec![0u8; 8];
    hdlr.extend_from_slice(t.handler);
    hdlr.extend_from_slice(&[0u8; 13]);
    let mut stsd = vec![0, 0, 0, 0, 0, 0, 0, 1 + u8::from(t.extra.is_some())];
    stsd.extend(bx(t.fourcc, &[0u8; 8]));
    if let Some(x) = t.extra {
        stsd.extend(bx(x, &[0u8; 8]));
    }
    let mut stts = vec![0, 0, 0, 0, 0, 0, 0, 1];
    stts.extend_from_slice(&(t.fps * seconds).to_be_bytes());
    stts.extend_from_slice(&(ts / t.fps.max(1)).to_be_bytes());
    let mut stbl = bx(b"stsd", &stsd);
    stbl.extend(bx(b"stts", &stts));
    let mut mdia = bx(b"mdhd", &mdhd);
    mdia.extend(bx(b"hdlr", &hdlr));
    mdia.extend(bx(b"minf", &bx(b"stbl", &stbl)));
    let mut trak = bx(b"tkhd", &tkhd);
    trak.extend(bx(b"mdia", &mdia));
    bx(b"trak", &trak)
}

fn mp4_moov(seconds: u32, tracks: &[MTrack]) -> Vec<u8> {
    let mut mvhd = vec![0u8; 12];
    mvhd.extend_from_slice(&1000u32.to_be_bytes());
    mvhd.extend_from_slice(&(seconds * 1000).to_be_bytes());
    mvhd.extend_from_slice(&[0u8; 80]);
    let mut moov = bx(b"mvhd", &mvhd);
    for t in tracks {
        moov.extend(mp4_trak(t, seconds));
    }
    bx(b"moov", &moov)
}

fn mp4(seconds: u32, tracks: &[MTrack]) -> Vec<u8> {
    let mut v = bx(b"ftyp", b"isom\0\0\0\0isomiso2mp41");
    v.extend(mp4_moov(seconds, tracks));
    v.extend(bx(b"mdat", &[0u8; 64]));
    v
}

fn pad(mut v: Vec<u8>, to: usize) -> Vec<u8> {
    v.resize(to, 0);
    v
}

fn vet_bytes(slot: Slot, name: &str, bytes: &[u8]) -> (Outcome, tempfile::TempDir) {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    let o = run(slot, write(src.path(), name, bytes), out.path());
    (o, out)
}

fn accepted(slot: Slot, name: &str, bytes: &[u8]) {
    let (o, out) = vet_bytes(slot, name, bytes);
    let f = files(&o);
    assert_eq!(f.len(), 1);
    assert_eq!(std::fs::read(&f[0]).unwrap(), bytes, "copied unchanged");
    assert!(f[0].starts_with(out.path()));
}

fn refused(slot: Slot, name: &str, bytes: &[u8], want: &str) {
    let (o, out) = vet_bytes(slot, name, bytes);
    assert_eq!(code(&o), want, "{o:?}");
    assert!(
        std::fs::read_dir(out.path()).unwrap().next().is_none(),
        "nothing written"
    );
}

const MIB: usize = 1024 * 1024;

#[test]
fn accepted_webm_and_mp4() {
    accepted(
        Slot::Trailer,
        "t.webm",
        &webm(60.0, &[vtrack("V_VP9", 1920, 1080, 60), atrack("A_OPUS")]),
    );
    accepted(
        Slot::Trailer,
        "t.webm",
        &webm(60.0, &[vtrack("V_AV1", 1280, 720, 30), atrack("A_OPUS")]),
    );
    accepted(
        Slot::Trailer,
        "t.mp4",
        &mp4(60, &[mv(b"avc1", 1920, 1080, 30), ma(b"mp4a")]),
    );
    // no audio at all is fine for a trailer; the file name does not matter
    accepted(
        Slot::Trailer,
        "t.bin",
        &webm(10.0, &[vtrack("V_VP9", 640, 360, 24)]),
    );
    accepted(
        Slot::Preview,
        "p.webm",
        &webm(10.0, &[vtrack("V_VP9", 1280, 720, 30)]),
    );
    accepted(
        Slot::Preview,
        "p.mp4",
        &mp4(10, &[mv(b"avc1", 1280, 720, 30)]),
    );
}

#[test]
fn output_name_comes_from_the_container() {
    let (o, _out) = vet_bytes(
        Slot::Preview,
        "evil.exe",
        &mp4(5, &[mv(b"avc1", 640, 360, 30)]),
    );
    assert_eq!(files(&o)[0].file_name().unwrap(), "preview.mp4");
    let (o, _out) = vet_bytes(
        Slot::Trailer,
        "../x.mp4",
        &webm(5.0, &[vtrack("V_VP9", 640, 360, 30)]),
    );
    assert_eq!(files(&o)[0].file_name().unwrap(), "trailer.webm");
}

#[test]
fn moov_after_mdat_is_found() {
    let mut v = bx(b"ftyp", b"isom\0\0\0\0isom");
    v.extend(bx(b"mdat", &[0u8; 4096]));
    v.extend(mp4_moov(10, &[mv(b"avc1", 1280, 720, 30)]));
    accepted(Slot::Preview, "p.mp4", &v);
}

#[test]
fn codec_and_container_allow_list() {
    let vp9 = vtrack("V_VP9", 1280, 720, 30);
    // H.264 inside WebM, VP8, VP9 inside MP4, HEVC and AV1 in MP4
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[vtrack("V_MPEG4/ISO/AVC", 1280, 720, 30)]),
        codes::CODEC_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[vtrack("V_VP8", 1280, 720, 30)]),
        codes::CODEC_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"vp09", 1280, 720, 30)]),
        codes::CODEC_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"hvc1", 1280, 720, 30)]),
        codes::CODEC_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"av01", 1280, 720, 30)]),
        codes::CODEC_NOT_ALLOWED,
    );
    // audio codecs
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[vp9, atrack("A_VORBIS")]),
        codes::CODEC_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"avc1", 1280, 720, 30), ma(b"ac-3")]),
        codes::CODEC_NOT_ALLOWED,
    );
    // containers
    refused(
        Slot::Trailer,
        "a.webm",
        &webm_doc("matroska", 10.0, &[vtrack("V_VP9", 1280, 720, 30)]),
        codes::CONTAINER_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.avi",
        b"RIFF\x00\x00\x00\x00AVI LIST",
        codes::CONTAINER_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &[0xAB; 4096],
        codes::CONTAINER_NOT_ALLOWED,
    );
    refused(Slot::Trailer, "a.mp4", b"", codes::CONTAINER_NOT_ALLOWED);
}

#[test]
fn tracks_other_than_one_video_and_one_audio_are_refused() {
    let v = || vtrack("V_VP9", 1280, 720, 30);
    let sub = WTrack {
        kind: 0x11,
        codec: "S_TEXT/UTF8",
        w: 0,
        h: 0,
        fps: None,
        enc: false,
    };
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[v(), sub]),
        codes::TRACK_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[v(), v()]),
        codes::TRACK_NOT_ALLOWED,
    );
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[atrack("A_OPUS")]),
        codes::NO_VIDEO_TRACK,
    );
    let text = MTrack {
        handler: b"text",
        fourcc: b"tx3g",
        w: 0,
        h: 0,
        fps: 0,
        extra: None,
    };
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"avc1", 1280, 720, 30), text]),
        codes::TRACK_NOT_ALLOWED,
    );
}

#[test]
fn preview_with_an_audio_track_is_refused() {
    refused(
        Slot::Preview,
        "p.webm",
        &webm(10.0, &[vtrack("V_VP9", 1280, 720, 30), atrack("A_OPUS")]),
        codes::AUDIO_NOT_ALLOWED,
    );
    refused(
        Slot::Preview,
        "p.mp4",
        &mp4(10, &[mv(b"avc1", 1280, 720, 30), ma(b"mp4a")]),
        codes::AUDIO_NOT_ALLOWED,
    );
}

#[test]
fn duration_resolution_and_frame_rate_limits() {
    let v = |w, h, fps| vtrack("V_VP9", w, h, fps);
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(121.0, &[v(1280, 720, 30)]),
        codes::TOO_LONG,
    );
    refused(
        Slot::Preview,
        "a.webm",
        &webm(16.0, &[v(1280, 720, 30)]),
        codes::TOO_LONG,
    );
    accepted(Slot::Preview, "a.webm", &webm(15.0, &[v(1280, 720, 30)]));
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(121, &[mv(b"avc1", 1280, 720, 30)]),
        codes::TOO_LONG,
    );
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[v(3840, 2160, 30)]),
        codes::RESOLUTION_TOO_LARGE,
    );
    refused(
        Slot::Preview,
        "a.webm",
        &webm(10.0, &[v(1920, 1080, 30)]),
        codes::RESOLUTION_TOO_LARGE,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"avc1", 3840, 2160, 30)]),
        codes::RESOLUTION_TOO_LARGE,
    );
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[v(1920, 1080, 120)]),
        codes::FRAME_RATE_TOO_HIGH,
    );
    refused(
        Slot::Preview,
        "a.webm",
        &webm(10.0, &[v(1280, 720, 60)]),
        codes::FRAME_RATE_TOO_HIGH,
    );
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"avc1", 1920, 1080, 120)]),
        codes::FRAME_RATE_TOO_HIGH,
    );
    // a header without a duration cannot be vetted
    let mut no_dur = webm(10.0, &[v(1280, 720, 30)]);
    let at = no_dur.windows(2).position(|w| w == [0x44, 0x89]).unwrap();
    no_dur[at + 1] = 0x8A; // renames Duration to an unknown element, which is skipped
    refused(Slot::Trailer, "a.webm", &no_dur, codes::NO_DURATION);
}

#[test]
fn size_and_bitrate_limits() {
    let head = webm(10.0, &[vtrack("V_VP9", 1280, 720, 30)]);
    refused(
        Slot::Trailer,
        "a.webm",
        &pad(head.clone(), 80 * MIB + 1),
        codes::VIDEO_FILE_TOO_LARGE,
    );
    refused(
        Slot::Preview,
        "a.webm",
        &pad(head.clone(), 8 * MIB + 1),
        codes::VIDEO_FILE_TOO_LARGE,
    );
    // 4 MiB in 5 s is 6.7 Mbit/s: over the preview ceiling, small enough in size
    let short = webm(5.0, &[vtrack("V_VP9", 1280, 720, 30)]);
    refused(
        Slot::Preview,
        "a.webm",
        &pad(short, 4 * MIB),
        codes::BITRATE_TOO_HIGH,
    );
    // 40 MiB in 10 s is 33 Mbit/s for a trailer
    refused(
        Slot::Trailer,
        "a.webm",
        &pad(head.clone(), 40 * MIB),
        codes::BITRATE_TOO_HIGH,
    );
    accepted(Slot::Trailer, "a.webm", &pad(head, 8 * MIB));
}

#[test]
fn truncated_or_garbled_headers() {
    let full = webm(10.0, &[vtrack("V_VP9", 1280, 720, 30)]);
    // cut inside the Tracks element
    let at = full
        .windows(4)
        .position(|w| w == [0x16, 0x54, 0xAE, 0x6B])
        .unwrap()
        + 20;
    refused(Slot::Trailer, "a.webm", &full[..at], codes::HEADER_INVALID);
    // an MP4 with no moov, and one whose box claims more than the file holds
    let mut no_moov = bx(b"ftyp", b"isom\0\0\0\0isom");
    no_moov.extend(bx(b"mdat", &[0u8; 64]));
    refused(Slot::Trailer, "a.mp4", &no_moov, codes::HEADER_INVALID);
    let mut lying = bx(b"ftyp", b"isom\0\0\0\0isom");
    lying.extend_from_slice(&[0x7F, 0xFF, 0xFF, 0xFF]);
    lying.extend_from_slice(b"moov");
    refused(Slot::Trailer, "a.mp4", &lying, codes::HEADER_INVALID);
}

#[test]
fn missing_video_is_missing() {
    let src = tempdir().unwrap();
    let out = tempdir().unwrap();
    assert_eq!(
        run(Slot::Preview, src.path().join("no.webm"), out.path()),
        Outcome::Missing
    );
}

#[test]
fn a_track_with_two_sample_entries_is_refused() {
    // the first entry is allowed; the second must not hide behind it
    let v = MTrack {
        extra: Some(b"hvc1"),
        ..mv(b"avc1", 1280, 720, 30)
    };
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[v]),
        codes::SAMPLE_ENTRIES,
    );
    let a = MTrack {
        extra: Some(b"ac-3"),
        ..ma(b"mp4a")
    };
    refused(
        Slot::Trailer,
        "a.mp4",
        &mp4(10, &[mv(b"avc1", 1280, 720, 30), a]),
        codes::SAMPLE_ENTRIES,
    );
}

#[test]
fn compressed_or_encrypted_tracks_are_refused() {
    let t = WTrack {
        enc: true,
        ..vtrack("V_VP9", 1280, 720, 30)
    };
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[t]),
        codes::CONTENT_ENCODING,
    );
    let a = WTrack {
        enc: true,
        ..atrack("A_OPUS")
    };
    refused(
        Slot::Trailer,
        "a.webm",
        &webm(10.0, &[vtrack("V_VP9", 1280, 720, 30), a]),
        codes::CONTENT_ENCODING,
    );
}
