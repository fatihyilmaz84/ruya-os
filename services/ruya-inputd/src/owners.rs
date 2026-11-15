//! A pad remembers its player (RUY-124, ADR-017 amendment 1): per stable pad id, the last
//! non-guest profile seated on it. The shell starts "Who's playing?" on that profile's card;
//! nothing signs in by it. Kept in `<StateDirectory>/owners.json` (0600), written whole and
//! atomically, at most `MAX_PADS` pads (the oldest dropped).

use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;

pub const MAX_PADS: usize = 64;
const FILE: &str = "owners.json";

#[derive(Debug, Default)]
pub struct Owners {
    /// `None`: in memory only (development, tests).
    dir: Option<PathBuf>,
    /// (stable pad id, profile), the oldest first.
    list: Vec<(String, String)>,
    /// The file exists but could not be read: it is never overwritten (services/CLAUDE.md).
    unreadable: bool,
    journal: Vec<String>,
}

impl Owners {
    pub fn in_memory() -> Self {
        Owners::default()
    }

    /// Reads `dir/owners.json`. Missing means no owners; unreadable (not UTF-8, not the expected
    /// JSON, an I/O error) also means none, is journaled, and the file is left alone.
    pub fn load(dir: PathBuf) -> Self {
        let mut owners = Owners {
            dir: Some(dir.clone()),
            ..Owners::default()
        };
        let path = dir.join(FILE);
        match fs::read_to_string(&path) {
            Ok(text) => match parse(&text) {
                Some(list) => owners.list = list,
                None => owners.fail(format!(
                    "{}: not the expected JSON; no pad owners are known, and the file is kept",
                    path.display()
                )),
            },
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => owners.fail(format!(
                "{}: {e}; no pad owners are known, and the file is kept",
                path.display()
            )),
        }
        owners
    }

    fn fail(&mut self, line: String) {
        self.unreadable = true;
        self.journal.push(line);
    }

    pub fn take_journal(&mut self) -> Vec<String> {
        std::mem::take(&mut self.journal)
    }

    /// The profile recorded for the pad, whatever it is now (the caller checks the account).
    pub fn get(&self, pad: &str) -> Option<&str> {
        self.list
            .iter()
            .find(|(p, _)| p == pad)
            .map(|(_, profile)| profile.as_str())
    }

    /// Records `profile` as the pad's owner (the newest entry). `live` says whether an entry's
    /// profile is still a profile account: the ones that are not are dropped as the file is
    /// written. Returns whether the pad's owner changed.
    pub fn record(&mut self, pad: &str, profile: &str, live: &dyn Fn(&str) -> bool) -> bool {
        let before = self.get(pad).map(str::to_owned);
        if before.as_deref() == Some(profile) && self.list.last().is_some_and(|(p, _)| p == pad) {
            return false; // already the newest: nothing to write
        }
        self.list.retain(|(p, _)| p != pad);
        self.list.push((pad.to_owned(), profile.to_owned()));
        self.list.retain(|(_, who)| live(who));
        while self.list.len() > MAX_PADS {
            self.list.remove(0);
        }
        self.write();
        before.as_deref() != Some(profile)
    }

    fn write(&mut self) {
        let Some(dir) = self.dir.clone() else {
            return;
        };
        if self.unreadable {
            return; // never overwritten while unreadable; the owners live in memory this run
        }
        if let Err(e) = write_atomic(&dir, &self.list) {
            self.journal.push(format!(
                "{}: could not be written: {e}",
                dir.join(FILE).display()
            ));
        }
    }
}

fn parse(text: &str) -> Option<Vec<(String, String)>> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let mut out = Vec::new();
    for entry in value.as_array()? {
        let pad = entry.get("pad")?.as_str()?;
        let profile = entry.get("profile")?.as_str()?;
        out.push((pad.to_owned(), profile.to_owned()));
    }
    while out.len() > MAX_PADS {
        out.remove(0);
    }
    Some(out)
}

fn write_atomic(dir: &std::path::Path, list: &[(String, String)]) -> io::Result<()> {
    let entries: Vec<serde_json::Value> = list
        .iter()
        .map(|(pad, profile)| serde_json::json!({ "pad": pad, "profile": profile }))
        .collect();
    let text = serde_json::to_string(&entries).map_err(io::Error::other)?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join("owners.json.tmp");
    let _ = fs::remove_file(&tmp);
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        fs::rename(&tmp, dir.join(FILE))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all(_: &str) -> bool {
        true
    }

    #[test]
    fn the_owner_survives_a_restart_and_the_file_is_private() {
        let dir = tempfile::tempdir().expect("dir");
        let mut o = Owners::load(dir.path().to_path_buf());
        assert!(o.record("usb-1", "p2", &all));
        let again = Owners::load(dir.path().to_path_buf());
        assert_eq!(again.get("usb-1"), Some("p2"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(dir.path().join(FILE))
                .expect("file")
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert!(!dir.path().join("owners.json.tmp").exists());
    }

    #[test]
    fn the_last_profile_wins_and_the_same_one_changes_nothing() {
        let mut o = Owners::in_memory();
        assert!(o.record("a", "p1", &all));
        assert!(!o.record("a", "p1", &all));
        assert!(o.record("a", "p2", &all));
        assert_eq!(o.get("a"), Some("p2"));
    }

    #[test]
    fn an_owner_without_an_account_is_dropped_at_the_next_write() {
        let dir = tempfile::tempdir().expect("dir");
        let mut o = Owners::load(dir.path().to_path_buf());
        o.record("a", "gone", &all);
        o.record("b", "p1", &|who| who != "gone");
        assert_eq!(o.get("a"), None);
        let again = Owners::load(dir.path().to_path_buf());
        assert_eq!(again.get("a"), None);
        assert_eq!(again.get("b"), Some("p1"));
    }

    #[test]
    fn the_65th_pad_drops_the_oldest() {
        let mut o = Owners::in_memory();
        for i in 0..=MAX_PADS {
            o.record(&format!("pad{i}"), "p1", &all);
        }
        assert_eq!(o.get("pad0"), None);
        assert_eq!(o.get("pad1"), Some("p1"));
        assert_eq!(o.get(&format!("pad{MAX_PADS}")), Some("p1"));
        assert_eq!(o.list.len(), MAX_PADS);
    }

    #[test]
    fn an_unreadable_file_is_journaled_and_never_overwritten() {
        let dir = tempfile::tempdir().expect("dir");
        fs::write(dir.path().join(FILE), b"{ not json").expect("write");
        let mut o = Owners::load(dir.path().to_path_buf());
        assert_eq!(o.take_journal().len(), 1);
        assert_eq!(o.get("a"), None);
        o.record("a", "p1", &all);
        assert_eq!(o.get("a"), Some("p1"), "known for this run");
        assert_eq!(
            fs::read(dir.path().join(FILE)).expect("kept"),
            b"{ not json"
        );
    }

    #[test]
    fn a_missing_file_means_no_owners_without_a_complaint() {
        let dir = tempfile::tempdir().expect("dir");
        let mut o = Owners::load(dir.path().to_path_buf());
        assert!(o.take_journal().is_empty());
        assert_eq!(o.get("a"), None);
    }
}
