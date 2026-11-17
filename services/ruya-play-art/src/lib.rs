//! Vetting of the art and video files of a `.play` package (05 sections 5, 9.1 and 12).
//!
//! The caller (the importer's unpack helper, RUY-99) gives a list of `(slot, path)` pairs and an
//! output directory; for each slot it gets one [`Outcome`]:
//!
//! * images are checked by magic bytes and header (format, size, aspect, animation) **before**
//!   any pixel is decoded, decoded by memory-safe Rust codecs, converted to sRGB, stripped of all
//!   metadata and re-encoded as lossless WebP at the canonical sizes of 05 section 12;
//! * videos (`trailer`, `preview`) are only checked against a container and codec allow-list by
//!   reading their headers; a vetted file is copied unchanged.
//!
//! This crate opens nothing but the given input files and writes nothing but files in the output
//! directory. It does not depend on the package-format crate.

mod image_art;
mod video;

use std::path::{Path, PathBuf};

pub use image_art::{peak_decode_bytes, MAX_DIMENSION, MAX_PIXELS};

/// An art or video slot of a package (05 section 5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Slot {
    Icon,
    Logo,
    Hero,
    Cover,
    /// Index into `screenshots[]` (0-based, at most [`MAX_SCREENSHOTS`] - 1).
    Screenshot(u8),
    /// `trailer.poster`
    TrailerPoster,
    Trailer,
    Preview,
}

/// At most this many screenshots (05 section 5).
pub const MAX_SCREENSHOTS: u8 = 20;

impl Slot {
    /// Stable name used in output file names and messages: `icon`, `screenshot-3`, ...
    pub fn key(self) -> String {
        match self {
            Slot::Icon => "icon".into(),
            Slot::Logo => "logo".into(),
            Slot::Hero => "hero".into(),
            Slot::Cover => "cover".into(),
            Slot::Screenshot(i) => format!("screenshot-{i}"),
            Slot::TrailerPoster => "trailer-poster".into(),
            Slot::Trailer => "trailer".into(),
            Slot::Preview => "preview".into(),
        }
    }
}

/// What happened to one slot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Vetted; these canonical files were written (absolute under the output directory).
    Ok { files: Vec<PathBuf> },
    /// The file does not exist. Not an error for an optional slot.
    Missing,
    /// Refused. `code` is a stable dotted string (`art.*` or `video.*`, see the constants in
    /// [`codes`]); `message` is for logs, not for the UI.
    Invalid { code: &'static str, message: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlotResult {
    pub slot: Slot,
    pub outcome: Outcome,
}

/// Stable error codes.
pub mod codes {
    pub const NOT_A_FILE: &str = "art.not_a_file";
    pub const FILE_TOO_LARGE: &str = "art.file_too_large";
    pub const IO: &str = "art.io";
    pub const SVG: &str = "art.svg";
    pub const MAGIC_MISMATCH: &str = "art.magic_mismatch";
    pub const FORMAT_UNSUPPORTED: &str = "art.format_unsupported";
    pub const ANIMATED: &str = "art.animated";
    pub const CORRUPT: &str = "art.corrupt";
    pub const DIMENSIONS_TOO_LARGE: &str = "art.dimensions_too_large";
    pub const TOO_SMALL: &str = "art.too_small";
    pub const ASPECT_RATIO: &str = "art.aspect_ratio";
    pub const COLOUR_PROFILE: &str = "art.colour_profile";
    pub const ICC_TOO_LARGE: &str = "art.icc_too_large";
    pub const TOO_MANY_SCREENSHOTS: &str = "art.too_many_screenshots";

    pub const VIDEO_NOT_A_FILE: &str = "video.not_a_file";
    pub const VIDEO_IO: &str = "video.io";
    pub const VIDEO_FILE_TOO_LARGE: &str = "video.file_too_large";
    pub const CONTAINER_NOT_ALLOWED: &str = "video.container_not_allowed";
    pub const HEADER_INVALID: &str = "video.header_invalid";
    pub const NO_VIDEO_TRACK: &str = "video.no_video_track";
    pub const CODEC_NOT_ALLOWED: &str = "video.codec_not_allowed";
    pub const SAMPLE_ENTRIES: &str = "video.sample_entries";
    pub const CONTENT_ENCODING: &str = "video.content_encoding";
    pub const TRACK_NOT_ALLOWED: &str = "video.track_not_allowed";
    pub const AUDIO_NOT_ALLOWED: &str = "video.audio_not_allowed";
    pub const NO_DURATION: &str = "video.no_duration";
    pub const TOO_LONG: &str = "video.too_long";
    pub const RESOLUTION_TOO_LARGE: &str = "video.resolution_too_large";
    pub const FRAME_RATE_TOO_HIGH: &str = "video.frame_rate_too_high";
    pub const BITRATE_TOO_HIGH: &str = "video.bitrate_too_high";
}

pub(crate) struct Fail {
    pub code: &'static str,
    pub message: String,
}

pub(crate) fn fail<T>(code: &'static str, message: impl Into<String>) -> Result<T, Fail> {
    Err(Fail {
        code,
        message: message.into(),
    })
}

/// Open a file once and check it on the open handle (no check-then-open race): a symlink, a
/// reparse point or anything that is not a regular file is `not_a_file`. Returns the handle and
/// its size.
pub(crate) fn open_regular(
    path: &Path,
    not_a_file: &'static str,
    io_code: &'static str,
) -> Result<(std::fs::File, u64), Fail> {
    let mut o = std::fs::OpenOptions::new();
    o.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        o.custom_flags(0x0020_0000); // FILE_FLAG_OPEN_REPARSE_POINT: do not follow
    }
    let file = match o.open(path) {
        Ok(f) => f,
        Err(e) => {
            return match std::fs::symlink_metadata(path) {
                Ok(m) if !m.is_file() => fail(not_a_file, "not a regular file"),
                _ => fail(io_code, format!("{}: {e}", path.display())),
            }
        }
    };
    let meta = file.metadata().map_err(|e| Fail {
        code: io_code,
        message: e.to_string(),
    })?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return fail(not_a_file, "a reparse point is not a regular file");
        }
    }
    if !meta.is_file() {
        return fail(not_a_file, "not a regular file");
    }
    Ok((file, meta.len()))
}

/// Read at most `max` bytes from the handle; one byte more means the file is too large (it may
/// have grown since `open_regular` looked at it).
pub(crate) fn read_limited(
    file: &mut std::fs::File,
    max: u64,
    too_large: &'static str,
    io_code: &'static str,
) -> Result<Vec<u8>, Fail> {
    use std::io::Read;
    let mut v = Vec::new();
    file.take(max + 1).read_to_end(&mut v).map_err(|e| Fail {
        code: io_code,
        message: e.to_string(),
    })?;
    if v.len() as u64 > max {
        return fail(too_large, format!("more than {max} bytes"));
    }
    Ok(v)
}

/// True when the slot is malformed and the package must be refused: a broken `icon` or `hero`
/// (05 section 5). Other invalid slots only lose that art.
pub fn refuses_package(results: &[SlotResult]) -> bool {
    results.iter().any(|r| {
        matches!(r.slot, Slot::Icon | Slot::Hero) && matches!(r.outcome, Outcome::Invalid { .. })
    })
}

/// Vet every `(slot, path)` and write the canonical files into `out_dir` (created if needed).
/// Results come back in input order. Nothing is written for an invalid slot.
pub fn vet(inputs: &[(Slot, PathBuf)], out_dir: &Path) -> Vec<SlotResult> {
    inputs
        .iter()
        .map(|(slot, path)| SlotResult {
            slot: *slot,
            outcome: vet_one(*slot, path, out_dir),
        })
        .collect()
}

fn vet_one(slot: Slot, path: &Path, out_dir: &Path) -> Outcome {
    if let Slot::Screenshot(i) = slot {
        if i >= MAX_SCREENSHOTS {
            return Outcome::Invalid {
                code: codes::TOO_MANY_SCREENSHOTS,
                message: format!("screenshot index {i}: at most {MAX_SCREENSHOTS} screenshots"),
            };
        }
    }
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Outcome::Missing,
        _ => {}
    }
    let result = match slot {
        Slot::Trailer | Slot::Preview => video::vet_video(slot, path, out_dir),
        _ => image_art::vet_image(slot, path, out_dir),
    };
    match result {
        Ok(files) => Outcome::Ok { files },
        Err(f) => Outcome::Invalid {
            code: f.code,
            message: f.message,
        },
    }
}

/// Number of pixel decodes started in this thread (test hook: header checks must refuse a file
/// before any decode, so a bomb never reaches a decoder).
#[doc(hidden)]
pub fn decode_count() -> usize {
    image_art::DECODES.with(|c| c.get())
}
