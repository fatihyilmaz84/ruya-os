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
