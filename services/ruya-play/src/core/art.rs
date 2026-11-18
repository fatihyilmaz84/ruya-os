//! The art step (05 §5, §7.3; lead-29 step 7): every art and video slot of the manifest is vetted
//! by `ruya-play-art` from the **staged** copy into the job's `art/` folder, and the per-slot
//! results join the one problem list. A broken `icon` or `hero` refuses the package
//! (`invalid-package`); another broken slot only loses that art (its problem is kept, the job can
//! still end `ok`). A logo per language is vetted into `art/logo-<n>/`, numbered in the order of
//! the manifest's map, so no package text becomes a file name.

use ruya_play_art::{Outcome, Slot, SlotResult};
use ruya_play_format::manifest::{Art, ArtPath};
use ruya_play_format::Problem;
use std::path::PathBuf;

/// One slot to vet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtInput {
    /// The slot.
    pub slot: Slot,
    /// The language of a per-language logo.
    pub lang: Option<String>,
    /// Its file in the package.
    pub package_path: String,
    /// The folder under `art/` its output goes to (`None`: `art/` itself).
    pub subdir: Option<String>,
}

/// The vetted files of one slot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VettedArt {
    /// `icon`, `screenshot-0`, ...
    pub slot: String,
    /// The language of a per-language logo.
    pub lang: Option<String>,
    /// The canonical files written.
    pub files: Vec<PathBuf>,
}

/// The slots of `art`, in the order of 05 §5.
pub fn inputs(art: &Art) -> Vec<ArtInput> {
    let one = |slot, path: &str| ArtInput {
        slot,
        lang: None,
        package_path: path.to_string(),
        subdir: None,
    };
    let mut v = vec![one(Slot::Icon, &art.icon)];
    match &art.logo {
        Some(ArtPath::One(p)) => v.push(one(Slot::Logo, p)),
        Some(ArtPath::PerLanguage(map)) => {
            for (n, (lang, p)) in map.iter().enumerate() {
                v.push(ArtInput {
                    slot: Slot::Logo,
                    lang: Some(lang.clone()),
                    package_path: p.clone(),
                    subdir: Some(format!("logo-{n}")),
                });
            }
        }
        None => {}
    }
    if let Some(p) = &art.hero {
        v.push(one(Slot::Hero, p));
    }
    if let Some(p) = &art.cover {
        v.push(one(Slot::Cover, p));
    }
    for (i, s) in art.screenshots.iter().enumerate() {
        let i = u8::try_from(i).unwrap_or(u8::MAX);
        v.push(one(Slot::Screenshot(i), &s.file));
    }
    if let Some(t) = &art.trailer {
        if let Some(poster) = &t.poster {
            v.push(one(Slot::TrailerPoster, poster));
        }
        v.push(one(Slot::Trailer, &t.file));
    }
    if let Some(p) = &art.preview {
        v.push(one(Slot::Preview, p));
    }
    v
}

/// The problem of an invalid slot (`art.*` or `video.*`), at the slot's package path.
pub fn problem_of(input: &ArtInput, result: &SlotResult) -> Option<Problem> {
    match &result.outcome {
        Outcome::Invalid { code, message } => {
            Some(Problem::new(code, &input.package_path, message.clone()))
        }
        _ => None,
    }
}

/// True when the results refuse the package (a broken icon or hero).
pub fn refuses(results: &[SlotResult]) -> bool {
    ruya_play_art::refuses_package(results)
}

/// The container a vetted art file must be in, judged from its first bytes (RUY-829).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Container {
    /// `RIFF` .. `WEBP`, the RIFF size matching the file.
    WebP,
    /// EBML (`1A 45 DF A3`).
    WebM,
    /// ISO-BMFF with `ftyp` first.
    Mp4,
}

const MIB: u64 = 1024 * 1024;

/// Room for the container's own chunks around the pixels of a lossless WebP.
const WEBP_SLACK: u64 = 64 * 1024;

/// The largest output `ruya-play-art` writes for a canonical image: 4 bytes per pixel of the
/// output's size plus the container (lossless WebP never needs more than the raw pixels).
const fn pixels(w: u64, h: u64) -> u64 {
    w * h * 4 + WEBP_SLACK
}

/// What a vetted art file named `name` (its last path component) may be: the container and the
/// most bytes. `None` for a name `ruya-play-art` never writes (05 §5's canonical files): the
/// service refuses it. Images are bounded by their output size (4 bytes a pixel), videos, which
/// are copied unchanged, by 05 §5's limits (trailer 80 MiB, preview 8 MiB).
pub fn vetted_file_limit(name: &str) -> Option<(Container, u64)> {
    let image = |stem: &str| -> Option<u64> {
        Some(match stem {
            "icon-512" => pixels(512, 512),
            "icon-256" => pixels(256, 256),
            "icon-128" => pixels(128, 128),
            // At most 4:1 wide at 512 high.
            "logo" => pixels(2048, 512),
            "hero-2160" => pixels(3840, 2160),
            "hero-1080" | "trailer-poster-1080" => pixels(1920, 1080),
            "card-540" => pixels(960, 540),
            "cover-900" => pixels(600, 900),
            _ => {
                let n = stem.strip_prefix("screenshot-")?;
                let (index, size) = n.split_once('-')?;
                let index: u8 = index.parse().ok()?;
                if index >= ruya_play_art::MAX_SCREENSHOTS || index.to_string() != index_text(n) {
                    return None;
                }
                match size {
                    "1080" => pixels(1920, 1080),
                    "thumb" => pixels(480, 270),
                    _ => return None,
                }
            }
        })
    };
    fn index_text(n: &str) -> &str {
        n.split('-').next().unwrap_or("")
    }
    let (stem, ext) = name.rsplit_once('.')?;
    match ext {
        "webp" => image(stem).map(|max| (Container::WebP, max)),
        "webm" | "mp4" => {
            let c = if ext == "webm" {
                Container::WebM
            } else {
                Container::Mp4
            };
            match stem {
                "trailer" => Some((c, 80 * MIB)),
                "preview" => Some((c, 8 * MIB)),
                _ => None,
            }
        }
        _ => None,
    }
}

/// How many leading bytes [`header_matches`] looks at.
pub const HEADER_BYTES: usize = 12;

/// True when `head` (the first [`HEADER_BYTES`] of a file of `len` bytes) starts the container.
pub fn header_matches(container: Container, head: &[u8], len: u64) -> bool {
    match container {
        Container::WebP => {
            if head.len() < 12 || &head[..4] != b"RIFF" || &head[8..12] != b"WEBP" {
                return false;
            }
            let riff = u32::from_le_bytes([head[4], head[5], head[6], head[7]]);
            u64::from(riff) + 8 == len
        }
        Container::WebM => head.len() >= 4 && head[..4] == [0x1A, 0x45, 0xDF, 0xA3],
        Container::Mp4 => head.len() >= 8 && &head[4..8] == b"ftyp",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn webp(len: u32) -> Vec<u8> {
        let mut v = b"RIFF".to_vec();
        v.extend_from_slice(&(len - 8).to_le_bytes());
        v.extend_from_slice(b"WEBP");
        v
    }

    #[test]
    fn only_canonical_names_have_a_limit() {
        assert_eq!(
            vetted_file_limit("icon-512.webp"),
            Some((Container::WebP, 512 * 512 * 4 + WEBP_SLACK))
        );
        assert_eq!(
            vetted_file_limit("screenshot-19-thumb.webp"),
            Some((Container::WebP, 480 * 270 * 4 + WEBP_SLACK))
        );
        assert_eq!(
            vetted_file_limit("trailer.webm"),
            Some((Container::WebM, 80 * MIB))
        );
        assert_eq!(
            vetted_file_limit("preview.mp4"),
            Some((Container::Mp4, 8 * MIB))
        );
        for bad in [
            "icon-512.png",
            "icon.webp",
            "screenshot-20-1080.webp",
            "screenshot-01-1080.webp",
            "screenshot-1-720.webp",
            "trailer.webp",
            "hero-2160.webm",
            "payload.so",
            "",
        ] {
            assert_eq!(vetted_file_limit(bad), None, "{bad}");
        }
    }

    #[test]
    fn the_header_must_start_the_container() {
        assert!(header_matches(Container::WebP, &webp(100), 100));
        // A RIFF size that does not match the file: cut off or padded.
        assert!(!header_matches(Container::WebP, &webp(100), 101));
        let mut wave = webp(100);
        wave[8..12].copy_from_slice(b"WAVE");
        assert!(!header_matches(Container::WebP, &wave, 100));
        assert!(!header_matches(
            Container::WebP,
            b"\x89PNG\r\n\x1a\n\0\0\0\0",
            12
        ));
        assert!(header_matches(
            Container::WebM,
            &[0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0, 0, 0, 0, 0],
            12
        ));
        assert!(!header_matches(Container::WebM, b"RIFF", 4));
        assert!(header_matches(Container::Mp4, b"\0\0\0\x18ftypisom", 24));
        assert!(!header_matches(Container::Mp4, b"\0\0\0\x18moovisom", 24));
        assert!(!header_matches(Container::Mp4, b"ftyp", 4));
    }
}
