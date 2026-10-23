//! Channel levels persisted as one small TOML file, written atomically. A file that exists but
//! can't be read is an error: it is never overwritten silently.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

fn full() -> u32 {
    100
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Channels {
    #[serde(default = "full")]
    pub ui: u32,
    #[serde(default = "full")]
    pub ambient: u32,
    #[serde(default = "full")]
    pub media: u32,
}

impl Default for Channels {
    fn default() -> Self {
        Channels {
            ui: 100,
            ambient: 100,
            media: 100,
        }
    }
}

pub struct Store {
    path: Option<PathBuf>,
}

impl Store {
    /// A store that keeps nothing (tests and `--session` without a state file).
    pub fn in_memory() -> Store {
        Store { path: None }
    }

    pub fn at(path: &Path) -> Store {
        Store {
            path: Some(path.to_owned()),
        }
    }

    /// Missing file = defaults. Unreadable or malformed file = error.
    pub fn load(&self) -> io::Result<Channels> {
        let Some(path) = &self.path else {
            return Ok(Channels::default());
        };
        match fs::read_to_string(path) {
            Ok(text) => {
                let mut c: Channels = toml::from_str(&text)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
                c.ui = c.ui.min(100);
                c.ambient = c.ambient.min(100);
                c.media = c.media.min(100);
                Ok(c)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Channels::default()),
            Err(e) => Err(e),
        }
    }

    pub fn save(&self, channels: &Channels) -> io::Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let text = toml::to_string_pretty(channels)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_gives_full_levels() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::at(&dir.path().join("audio.toml"));
        assert_eq!(store.load().unwrap(), Channels::default());
    }

    #[test]
    fn levels_survive_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub").join("audio.toml");
        let c = Channels {
            ui: 30,
            ambient: 0,
            media: 80,
        };
        Store::at(&path).save(&c).unwrap();
        assert_eq!(Store::at(&path).load().unwrap(), c);
        assert!(!dir.path().join("sub").join("audio.toml.tmp").exists());
    }

    #[test]
    fn corrupt_file_is_an_error_not_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audio.toml");
        fs::write(&path, "ui = \"loud\"").unwrap();
        assert!(Store::at(&path).load().is_err());
    }

    #[test]
    fn stored_values_above_100_are_clamped_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audio.toml");
        fs::write(&path, "ui = 250\n").unwrap();
        let c = Store::at(&path).load().unwrap();
        assert_eq!((c.ui, c.ambient), (100, 100));
    }
}
