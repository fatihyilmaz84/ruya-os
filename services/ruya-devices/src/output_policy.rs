//! The sound output policy of spec 03 section 2.3 (T-322): which of the card's outputs is the
//! default. Pure: the outputs, the saved choice and the rejected outputs go in, a ranking comes
//! out. The saved choice is a small TOML file next to the channel levels, written atomically.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutKind {
    Speaker,
    Headphones,
    Hdmi,
    Usb,
    Bluetooth,
}

impl OutKind {
    pub fn as_str(self) -> &'static str {
        match self {
            OutKind::Speaker => "speaker",
            OutKind::Headphones => "headphones",
            OutKind::Hdmi => "hdmi",
            OutKind::Usb => "usb",
            OutKind::Bluetooth => "bluetooth",
        }
    }
}

/// A route's `available`: jack or ELD detection. Internal speakers say `Unknown`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Avail {
    Yes,
    No,
    Unknown,
}

impl Avail {
    pub fn as_str(self) -> &'static str {
        match self {
            Avail::Yes => "yes",
            Avail::No => "no",
            Avail::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    /// Stable across boots: "<card>:<port>", or the node name of a sink without ports.
    pub id: String,
    pub name: String,
    pub kind: OutKind,
    pub card: String,
    pub port: String,
    pub available: Avail,
    /// The sink (`node.name`) of this output while its profile is the active one.
    pub node: Option<String>,
}

impl Output {
    /// A headset or headphones that are plugged in (usb, bluetooth, jack with `available = yes`).
    pub fn is_plugged_headset(&self) -> bool {
        match self.kind {
            OutKind::Usb | OutKind::Bluetooth => self.available != Avail::No,
            OutKind::Headphones => self.available == Avail::Yes,
            _ => false,
        }
    }

    /// An HDMI/DP output with a valid ELD (the monitor announced itself). An ELD alone does not
    /// prove speakers, which is why the player can reject it.
    pub fn has_eld(&self) -> bool {
        self.kind == OutKind::Hdmi && self.available == Avail::Yes
    }
}

/// The outputs best first: the saved choice, a plugged headset, an HDMI output with a valid ELD
/// that was not rejected, the internal speaker, anything else usable, and last what is
/// unplugged. An unavailable saved output is skipped (kept, not forgotten, by the caller).
pub fn rank<'a>(
    outputs: &'a [Output],
    saved: Option<&str>,
    rejected: &BTreeSet<String>,
) -> Vec<&'a Output> {
    let tier = |o: &Output| -> u8 {
        if o.available == Avail::No {
            return 6;
        }
        if saved == Some(o.id.as_str()) {
            return 0;
        }
        if o.is_plugged_headset() {
            1
        } else if o.has_eld() && !rejected.contains(&o.id) {
            2
        } else if o.kind == OutKind::Speaker {
            3
        } else if o.kind == OutKind::Hdmi && rejected.contains(&o.id) {
            5
        } else {
            4
        }
    };
    let mut ranked: Vec<&Output> = outputs.iter().collect();
    ranked.sort_by_key(|o| tier(o)); // stable: listing order inside a tier
    ranked
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Choice {
    #[serde(default)]
    pub saved: Option<String>,
    #[serde(default)]
    pub rejected: BTreeSet<String>,
    /// Outputs the console has used before (T-360): they keep the volume WirePlumber saved for
    /// them; any other starts at the first volume.
    #[serde(default)]
    pub seen: BTreeSet<String>,
}

pub struct ChoiceStore {
    path: Option<PathBuf>,
}

impl ChoiceStore {
    pub fn in_memory() -> ChoiceStore {
        ChoiceStore { path: None }
    }

    pub fn at(path: &Path) -> ChoiceStore {
        ChoiceStore {
            path: Some(path.to_owned()),
        }
    }

    /// Missing file = no choice. A file that can't be read is an error, never overwritten silently.
    pub fn load(&self) -> io::Result<Choice> {
        let Some(path) = &self.path else {
            return Ok(Choice::default());
        };
        match fs::read_to_string(path) {
            Ok(text) => {
                toml::from_str(&text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Choice::default()),
            Err(e) => Err(e),
        }
    }

    pub fn save(&self, choice: &Choice) -> io::Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let text = toml::to_string_pretty(choice)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut name = path.file_name().unwrap_or_default().to_os_string();
        name.push(".tmp");
        let tmp = path.with_file_name(name);
        fs::write(&tmp, text)?;
        fs::rename(&tmp, path)
    }
}

/// The loudest the test tone gets, as a share of full scale (T-347): the first-start sink
/// volume is high, so the tone itself must not be painful.
pub const TONE_CAP: f64 = 0.8;
/// The tone's own level, never above [`TONE_CAP`].
const TONE_LEVEL: f64 = 0.4;

/// A 0.4 s, 440 Hz tone as a 16-bit stereo 48 kHz WAV file, faded at both ends (no click):
/// what `TestOutput` plays.
pub fn tone_wav() -> Vec<u8> {
    const RATE: u32 = 48_000;
    let frames = RATE * 2 / 5;
    let mut data = Vec::with_capacity(frames as usize * 4);
    for i in 0..frames {
        let t = f64::from(i) / f64::from(RATE);
        let fade = (f64::from(i.min(frames - 1 - i)) / 2_400.0).min(1.0);
        let v = (t * 440.0 * std::f64::consts::TAU).sin() * fade * TONE_LEVEL.min(TONE_CAP);
        let s = (v * f64::from(i16::MAX)) as i16;
        for _ in 0..2 {
            data.extend_from_slice(&s.to_le_bytes());
        }
    }
    let mut wav = Vec::with_capacity(44 + data.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&2u16.to_le_bytes()); // channels
    wav.extend_from_slice(&RATE.to_le_bytes());
    wav.extend_from_slice(&(RATE * 4).to_le_bytes());
    wav.extend_from_slice(&4u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
    wav.extend_from_slice(&data);
    wav
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn out(id: &str, kind: OutKind, available: Avail) -> Output {
        Output {
            id: id.to_owned(),
            name: id.to_owned(),
            kind,
            card: "card".to_owned(),
            port: id.to_owned(),
            available,
            node: Some(id.to_owned()),
        }
    }

    fn first(outputs: &[Output], saved: Option<&str>, rejected: &[&str]) -> Option<String> {
        let rejected = rejected.iter().map(|s| (*s).to_owned()).collect();
        rank(outputs, saved, &rejected)
            .first()
            .map(|o| o.id.clone())
    }

    fn dell() -> Vec<Output> {
        vec![
            out("hdmi", OutKind::Hdmi, Avail::No),
            out("hp", OutKind::Headphones, Avail::No),
            out("spk", OutKind::Speaker, Avail::Unknown),
        ]
    }

    #[test]
    fn nothing_plugged_the_speaker() {
        assert_eq!(first(&dell(), None, &[]).as_deref(), Some("spk"));
    }

    #[test]
    fn hdmi_with_an_eld_beats_the_speaker() {
        let mut o = dell();
        o[0].available = Avail::Yes;
        assert_eq!(first(&o, None, &[]).as_deref(), Some("hdmi"));
        // Without a valid ELD (unknown) it does not.
        o[0].available = Avail::Unknown;
        assert_eq!(first(&o, None, &[]).as_deref(), Some("spk"));
    }

    #[test]
    fn a_headset_plugged_and_unplugged() {
        let mut o = dell();
        o[0].available = Avail::Yes;
        o[1].available = Avail::Yes;
        assert_eq!(first(&o, None, &[]).as_deref(), Some("hp"));
        o[1].available = Avail::No;
        assert_eq!(first(&o, None, &[]).as_deref(), Some("hdmi"));
        o.push(out("usb", OutKind::Usb, Avail::Unknown));
        o.push(out("bt", OutKind::Bluetooth, Avail::Yes));
        assert_eq!(first(&o, None, &[]).as_deref(), Some("usb"));
    }

    #[test]
    fn the_saved_choice_beats_the_rest() {
        let mut o = dell();
        o[0].available = Avail::Yes;
        o[1].available = Avail::Yes;
        assert_eq!(first(&o, Some("spk"), &[]).as_deref(), Some("spk"));
    }

    #[test]
    fn a_saved_output_that_is_gone_or_unplugged_is_skipped() {
        let mut o = dell();
        assert_eq!(first(&o, Some("tv"), &[]).as_deref(), Some("spk"));
        o[0].available = Avail::No;
        assert_eq!(first(&o, Some("hdmi"), &[]).as_deref(), Some("spk"));
    }

    #[test]
    fn a_rejected_monitor_stays_rejected() {
        let mut o = dell();
        o[0].available = Avail::Yes;
        assert_eq!(first(&o, None, &["hdmi"]).as_deref(), Some("spk"));
        // Last of the usable ones when nothing else exists.
        o.retain(|x| x.id == "hdmi");
        assert_eq!(first(&o, None, &["hdmi"]).as_deref(), Some("hdmi"));
    }

    #[test]
    fn whatever_exists_when_nothing_is_available() {
        let o = vec![out("hdmi", OutKind::Hdmi, Avail::No)];
        assert_eq!(first(&o, None, &[]).as_deref(), Some("hdmi"));
        assert_eq!(first(&[], None, &[]), None);
    }

    #[test]
    fn the_choice_survives_a_restart_and_a_corrupt_file_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("outputs.toml");
        assert_eq!(ChoiceStore::at(&path).load().unwrap(), Choice::default());
        let c = Choice {
            saved: Some("card:spk".to_owned()),
            rejected: BTreeSet::from(["card:hdmi".to_owned()]),
            seen: BTreeSet::from(["card:spk".to_owned()]),
        };
        ChoiceStore::at(&path).save(&c).unwrap();
        assert_eq!(ChoiceStore::at(&path).load().unwrap(), c);
        fs::write(&path, "saved = 3").unwrap();
        assert!(ChoiceStore::at(&path).load().is_err());
    }

    #[test]
    fn test_tone_is_capped_at_80_percent() {
        let w = tone_wav();
        let peak = w[44..]
            .chunks_exact(2)
            .map(|b| i32::from(i16::from_le_bytes([b[0], b[1]])).abs())
            .max()
            .unwrap();
        assert!(
            f64::from(peak) <= TONE_CAP * f64::from(i16::MAX),
            "peak {peak}"
        );
        assert!(peak > 1000, "still audible");
    }

    #[test]
    fn the_test_tone_is_a_wav_file() {
        let w = tone_wav();
        assert_eq!(&w[..4], b"RIFF");
        assert_eq!(&w[8..12], b"WAVE");
        assert_eq!(
            u32::from_le_bytes([w[40], w[41], w[42], w[43]]) as usize,
            w.len() - 44
        );
        assert!(w[44..].iter().any(|b| *b != 0), "not silence");
    }
}
