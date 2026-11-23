//! Each profile's choices in the library: the runner choice per `.play` game (RUY-959, 05 section
//! 6.2: `package`, the default, `bundled` or `system`, the values `ruya-play-launch` takes as
//! `--runner`, `ruya_play_launch::parse_choice`, ADR-037), and its say over its games (RUY-137,
//! `games::GameChoices`): the installations it linked and the one Play uses per game.
//!
//! One file per profile, `<dir>/<profile>.json` (`/var/lib/ruyaos/library`, the unit's
//! StateDirectory), format 2: `{"format":2,"choices":{"play.<id>":"bundled"},
//! "links":{"<anchor id>":["<item id>"]},"preferred":{"<game id>":"<item id>"}}`. A format 1 file
//! (`choices` only) reads as one with no links. Written atomically (tmp, sync, rename) like the
//! other services' stores, always as format 2. A profile with nothing left has no file. A file
//! that does not parse is logged and moved aside (`<profile>.json.corrupt-<time>`) before the next
//! write, never overwritten silently; until then the profile reads as having no choices.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::catalog::Item;
use crate::games::GameChoices;
use ruya_ids::valid_profile_id;

/// The choice a game has when its profile stored none.
pub const DEFAULT_CHOICE: &str = "package";
/// More than this in a profile's file is read as garbled (a choice or a link is a few dozen bytes).
const MAX_FILE_BYTES: u64 = 256 * 1024;

/// The answer of a choice call, and of the root-only calls (Library1 status strings).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    /// No item (an installation, or a game for SetPreferredInstallation) with that id is installed.
    Unknown,
    /// The item is not a `.play` app.
    NotPlay,
    /// A malformed profile id, a choice that is not one of the three, or an installation call that
    /// makes no sense (an installation linked to itself, one of another game, nothing to separate).
    Invalid,
    /// The choice could not be stored.
    Failed,
    /// A root-only call (PutProfileItems, SetActiveProfile) from a caller whose uid is not 0.
    NotAllowed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Unknown => "unknown",
            Status::NotPlay => "not_play",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
            Status::NotAllowed => "not_allowed",
        }
    }
}

/// The Flatpak id of the `.play` item `id` in `items`: the key its choice is stored under.
pub fn play_app(items: &[Item], id: &str) -> Result<String, Status> {
    let item = items.iter().find(|i| i.id == id).ok_or(Status::Unknown)?;
    if item.play.is_none() {
        return Err(Status::NotPlay);
    }
    item.id
        .strip_prefix("flatpak:")
        .map(str::to_owned)
        .ok_or(Status::NotPlay)
}

/// A known choice name (`ruya_play_launch::parse_choice`, the launcher's own list).
pub fn valid_choice(choice: &str) -> bool {
    ruya_play_launch::parse_choice(choice).is_some()
}

/// What one profile chose: the runner per `.play` game (Flatpak id to choice, never "package") and
/// its games' links and preferences.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProfileState {
    pub runners: BTreeMap<String, String>,
    pub games: GameChoices,
}

impl ProfileState {
    pub fn is_empty(&self) -> bool {
        self.runners.is_empty() && self.games.is_empty()
    }
}

/// The store of every profile's choices.
pub struct Choices {
    dir: PathBuf,
    /// One change at a time: a change reads, changes and writes a profile's file.
    writing: Mutex<()>,
}

/// What a profile's file says. Garbled when it does not parse.
enum Read {
    State(ProfileState),
    Garbled(String),
}

impl Choices {
    pub fn new(dir: impl Into<PathBuf>) -> Choices {
        Choices {
            dir: dir.into(),
            writing: Mutex::new(()),
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    fn path(&self, profile: &str) -> PathBuf {
        self.dir.join(format!("{profile}.json"))
    }

    fn read(&self, profile: &str) -> io::Result<Read> {
        let path = self.path(profile);
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(Read::State(ProfileState::default()))
            }
            Err(e) => return Err(e),
        };
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Ok(Read::Garbled("too big".into()));
        }
        Ok(match parse(&bytes) {
            Ok(state) => Read::State(state),
            Err(why) => Read::Garbled(why),
        })
    }

    /// Everything the profile chose: nothing when it chose nothing, or when the file is garbled
    /// (logged).
    pub fn state(&self, profile: &str) -> Result<ProfileState, Status> {
        if !valid_profile_id(profile) {
            return Err(Status::Invalid);
        }
        match self.read(profile) {
            Ok(Read::State(state)) => Ok(state),
            Ok(Read::Garbled(why)) => {
                eprintln!(
                    "ruya-library: {} is garbled ({why}); the profile reads as having no choices",
                    self.path(profile).display()
                );
                Ok(ProfileState::default())
            }
            Err(err) => {
                eprintln!(
                    "ruya-library: {} cannot be read: {err}",
                    self.path(profile).display()
                );
                Err(Status::Failed)
            }
        }
    }

    /// The profile's choice for the game with Flatpak id `app`: [`DEFAULT_CHOICE`] when none is
    /// stored (or the file is garbled, which is logged).
    pub fn get(&self, profile: &str, app: &str) -> Result<String, Status> {
        Ok(self
            .state(profile)?
            .runners
            .get(app)
            .cloned()
            .unwrap_or_else(|| DEFAULT_CHOICE.to_owned()))
    }

    /// Stores the profile's choice for `app` ([`DEFAULT_CHOICE`] removes the entry, and the file
    /// with its last entry). True when the choice differs from before.
    pub fn set(&self, profile: &str, app: &str, choice: &str) -> Result<bool, Status> {
        if !valid_profile_id(profile) || !valid_choice(choice) {
            return Err(Status::Invalid);
        }
        self.update(profile, |state| {
            let before = state
                .runners
                .get(app)
                .map_or(DEFAULT_CHOICE, String::as_str);
            if before == choice {
                return Ok(false);
            }
            if choice == DEFAULT_CHOICE {
                state.runners.remove(app);
            } else {
                state.runners.insert(app.to_owned(), choice.to_owned());
            }
            Ok(true)
        })
        .map(|(changed, _)| changed)
    }

    /// Changes the profile's state with `change` (Ok(true): it changed something) and stores the
    /// result; the file goes with the last choice. Answers whether it changed, and the state after.
    pub fn update(
        &self,
        profile: &str,
        change: impl FnOnce(&mut ProfileState) -> Result<bool, Status>,
    ) -> Result<(bool, ProfileState), Status> {
        if !valid_profile_id(profile) {
            return Err(Status::Invalid);
        }
        let _one = self.writing.lock().map_err(|_| Status::Failed)?;
        let path = self.path(profile);
        let fail = |err: io::Error| {
            eprintln!("ruya-library: {} cannot be written: {err}", path.display());
            Status::Failed
        };
        let mut state = match self.read(profile).map_err(fail)? {
            Read::State(state) => state,
            Read::Garbled(why) => {
                let aside = move_aside(&path).map_err(fail)?;
                eprintln!(
                    "ruya-library: {} is garbled ({why}); moved aside to {}, the profile starts with no choices",
                    path.display(),
                    aside.display()
                );
                ProfileState::default()
            }
        };
        if !change(&mut state)? {
            return Ok((false, state));
        }
        if state.is_empty() {
            match fs::remove_file(&path) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(fail(e)),
                _ => {}
            }
        } else {
            write_atomic(&self.dir, &path, &serialise(&state)).map_err(fail)?;
        }
        Ok((true, state))
    }
}

fn parse(bytes: &[u8]) -> Result<ProfileState, String> {
    let v: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    let format = v.get("format").and_then(serde_json::Value::as_u64);
    if !matches!(format, Some(1 | 2)) {
        return Err("not format 1 or 2".into());
    }
    // Format 1 has `choices` only, and always; format 2 writes all three.
    let object = |key: &str| match v.get(key) {
        Some(o) => o
            .as_object()
            .cloned()
            .ok_or_else(|| format!("{key} is not an object")),
        None if format == Some(2) || key != "choices" => Ok(serde_json::Map::new()),
        None => Err(format!("no {key}")),
    };
    let runners = object("choices")?
        .iter()
        .map(|(app, c)| match c.as_str() {
            Some(c) if valid_choice(c) && c != DEFAULT_CHOICE => Ok((app.clone(), c.to_owned())),
            _ => Err(format!("{app} has no valid choice")),
        })
        .collect::<Result<_, String>>()?;
    if format == Some(1) {
        return Ok(ProfileState {
            runners,
            games: GameChoices::default(),
        });
    }
    let item = |id: &str| match ruya_ids::parse_item(id) {
        Some(_) => Ok(id.to_owned()),
        None => Err(format!("{id:?} is not an item id")),
    };
    let links = object("links")?
        .iter()
        .map(|(anchor, members)| {
            let members = members
                .as_array()
                .filter(|m| !m.is_empty())
                .ok_or_else(|| format!("the link of {anchor} is not a list"))?
                .iter()
                .map(|m| {
                    m.as_str()
                        .map_or_else(|| Err("a link that is not text".into()), item)
                })
                .collect::<Result<Vec<String>, String>>()?;
            Ok((item(anchor)?, members))
        })
        .collect::<Result<_, String>>()?;
    let preferred = object("preferred")?
        .iter()
        .map(|(game, i)| {
            let i = i
                .as_str()
                .ok_or_else(|| format!("the preference of {game} is not text"))?;
            Ok((item(game)?, item(i)?))
        })
        .collect::<Result<_, String>>()?;
    Ok(ProfileState {
        runners,
        games: GameChoices { links, preferred },
    })
}

fn serialise(state: &ProfileState) -> Vec<u8> {
    serde_json::json!({
        "format": 2,
        "choices": state.runners,
        "links": state.games.links,
        "preferred": state.games.preferred,
    })
    .to_string()
    .into_bytes()
}

/// `path` written through `<path>.tmp`, on disk before the rename, so a power cut leaves the old
/// file or the new one.
fn write_atomic(dir: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let mut tmp = path.as_os_str().to_os_string();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// Renames `path` to `<path>.corrupt-<unix seconds>`, so a later garbled file never replaces an
/// earlier copy.
fn move_aside(path: &Path) -> io::Result<PathBuf> {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let mut name = path.as_os_str().to_os_string();
    name.push(format!(".corrupt-{secs}"));
    let aside = PathBuf::from(name);
    fs::rename(path, &aside)?;
    Ok(aside)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Kind, Source};
    use crate::play::PlayInfo;

    fn item(id: &str, play: bool) -> Item {
        Item {
            id: id.into(),
            kind: Kind::Game,
            title: id.into(),
            source: if id.starts_with("steam:") {
                Source::Steam
            } else {
                Source::Flatpak
            },
            launch: id.into(),
            art: Vec::new(),
            last_played: 0,
            play: play.then(PlayInfo::default),
            declared: Vec::new(),
        }
    }

    #[test]
    fn only_an_installed_play_item_takes_a_choice() {
        let items = [
            item("flatpak:play.com.example.hop", true),
            item("flatpak:org.example.App", false),
            item("flatpak:play.from.elsewhere", false),
            item("steam:220", false),
        ];
        assert_eq!(
            play_app(&items, "flatpak:play.com.example.hop").as_deref(),
            Ok("play.com.example.hop")
        );
        assert_eq!(
            play_app(&items, "flatpak:org.example.App"),
            Err(Status::NotPlay)
        );
        assert_eq!(
            play_app(&items, "flatpak:play.from.elsewhere"),
            Err(Status::NotPlay),
            "a play.* app of another remote is a plain item"
        );
        assert_eq!(play_app(&items, "steam:220"), Err(Status::NotPlay));
        assert_eq!(
            play_app(&items, "flatpak:play.not.installed"),
            Err(Status::Unknown)
        );
    }

    #[test]
    fn the_choice_is_per_profile_and_package_is_the_default() {
        let dir = tempfile::tempdir().unwrap();
        let c = Choices::new(dir.path());
        assert_eq!(c.get("p1", "play.a").as_deref(), Ok("package"));
        assert_eq!(c.set("p1", "play.a", "bundled"), Ok(true));
        assert_eq!(c.set("p2", "play.a", "system"), Ok(true));
        assert_eq!(c.get("p1", "play.a").as_deref(), Ok("bundled"));
        assert_eq!(c.get("p2", "play.a").as_deref(), Ok("system"));
        assert_eq!(c.get("p3", "play.a").as_deref(), Ok("package"));
        assert_eq!(c.get("p1", "play.b").as_deref(), Ok("package"));
        assert_eq!(c.set("p1", "play.a", "bundled"), Ok(false), "no change");
        assert!(dir.path().join("p1.json").is_file());
    }

    #[test]
    fn a_choice_survives_a_new_store_on_the_same_folder() {
        let dir = tempfile::tempdir().unwrap();
        Choices::new(dir.path())
            .set("p1", "play.a", "system")
            .unwrap();
        assert_eq!(
            Choices::new(dir.path()).get("p1", "play.a").as_deref(),
            Ok("system")
        );
    }

    #[test]
    fn package_clears_the_entry_and_the_last_one_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let c = Choices::new(dir.path());
        c.set("p1", "play.a", "bundled").unwrap();
        c.set("p1", "play.b", "system").unwrap();
        assert_eq!(c.set("p1", "play.a", "package"), Ok(true));
        assert_eq!(c.get("p1", "play.a").as_deref(), Ok("package"));
        let text = fs::read_to_string(dir.path().join("p1.json")).unwrap();
        assert!(!text.contains("play.a"), "{text}");
        assert_eq!(c.set("p1", "play.b", "package"), Ok(true));
        assert!(!dir.path().join("p1.json").exists());
        assert_eq!(c.set("p1", "play.b", "package"), Ok(false));
    }

    #[test]
    fn an_unknown_choice_or_a_malformed_profile_is_invalid() {
        let dir = tempfile::tempdir().unwrap();
        let c = Choices::new(dir.path());
        for choice in ["", "Bundled", "proton", "--runner=system"] {
            assert_eq!(
                c.set("p1", "play.a", choice),
                Err(Status::Invalid),
                "{choice}"
            );
        }
        for profile in ["", "../etc", "a/b", &"x".repeat(33)] {
            assert_eq!(
                c.set(profile, "play.a", "system"),
                Err(Status::Invalid),
                "{profile}"
            );
            assert_eq!(c.get(profile, "play.a"), Err(Status::Invalid), "{profile}");
        }
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn a_garbled_file_reads_as_no_choice_and_is_moved_aside_before_a_write() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("p1.json");
        fs::write(&file, b"{ not json").unwrap();
        let c = Choices::new(dir.path());
        assert_eq!(c.get("p1", "play.a").as_deref(), Ok("package"));
        assert_eq!(
            fs::read(&file).unwrap(),
            b"{ not json",
            "a read changes nothing"
        );
        assert_eq!(c.set("p1", "play.a", "system"), Ok(true));
        let aside: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("p1.json.corrupt-")
            })
            .collect();
        assert_eq!(aside.len(), 1);
        assert_eq!(fs::read(aside[0].path()).unwrap(), b"{ not json");
        assert_eq!(c.get("p1", "play.a").as_deref(), Ok("system"));
    }

    fn linked() -> GameChoices {
        let mut games = GameChoices::default();
        games.links.insert(
            "flatpak:org.example.Racer".into(),
            vec!["flatpak:play.org.example.racer".into()],
        );
        games.preferred.insert(
            "flatpak:org.example.Racer".into(),
            "flatpak:org.example.Racer".into(),
        );
        games
    }

    #[test]
    fn links_and_preferences_are_stored_with_the_runner_choices_as_format_2() {
        let dir = tempfile::tempdir().unwrap();
        let c = Choices::new(dir.path());
        c.set("p1", "play.a", "system").unwrap();
        let (changed, after) = c
            .update("p1", |s| {
                s.games = linked();
                Ok(true)
            })
            .unwrap();
        assert!(changed);
        assert_eq!(
            after.runners.get("play.a").map(String::as_str),
            Some("system")
        );
        let again = Choices::new(dir.path()).state("p1").unwrap();
        assert_eq!(again, after, "back after a restart");
        let text = fs::read_to_string(dir.path().join("p1.json")).unwrap();
        assert!(text.contains("\"format\":2"), "{text}");
        assert_eq!(
            c.state("p2").unwrap(),
            ProfileState::default(),
            "per profile"
        );
        // Nothing changed: nothing written.
        assert_eq!(c.update("p1", |_| Ok(false)).map(|(c, _)| c), Ok(false));
        // The last choice gone: the file goes.
        c.set("p1", "play.a", "package").unwrap();
        c.update("p1", |s| {
            s.games = GameChoices::default();
            Ok(true)
        })
        .unwrap();
        assert!(!dir.path().join("p1.json").exists());
    }

    #[test]
    fn a_format_1_file_reads_as_runner_choices_without_links() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join("p1.json"),
            br#"{"format":1,"choices":{"play.a":"bundled"}}"#,
        )
        .unwrap();
        let c = Choices::new(dir.path());
        let state = c.state("p1").unwrap();
        assert_eq!(
            state.runners.get("play.a").map(String::as_str),
            Some("bundled")
        );
        assert!(state.games.is_empty());
        // The next write is format 2, the old choice kept.
        c.update("p1", |s| {
            s.games = linked();
            Ok(true)
        })
        .unwrap();
        assert_eq!(c.get("p1", "play.a").as_deref(), Ok("bundled"));
        let text = fs::read_to_string(dir.path().join("p1.json")).unwrap();
        assert!(text.contains("\"format\":2"), "{text}");
    }

    #[test]
    fn a_link_or_preference_that_is_no_item_id_garbles_the_file() {
        for body in [
            r#"{"format":2,"choices":{},"links":{"flatpak:a":[]},"preferred":{}}"#,
            r#"{"format":2,"choices":{},"links":{"flatpak:a":["nope:1"]},"preferred":{}}"#,
            r#"{"format":2,"choices":{},"links":{"steam:x":["flatpak:a"]},"preferred":{}}"#,
            r#"{"format":2,"choices":{},"links":{},"preferred":{"flatpak:a":7}}"#,
            r#"{"format":2,"choices":{},"links":[],"preferred":{}}"#,
            r#"{"format":1}"#,
            r#"{"format":3,"choices":{}}"#,
        ] {
            assert!(parse(body.as_bytes()).is_err(), "{body}");
        }
        assert!(parse(br#"{"format":2}"#).unwrap().is_empty());
    }

    #[test]
    fn the_status_strings_are_the_contracts() {
        let all = [
            Status::Ok,
            Status::Unknown,
            Status::NotPlay,
            Status::Invalid,
            Status::Failed,
        ];
        let xml = include_str!("../../../api/dbus/org.ruyaos.Library1.xml");
        for s in all {
            assert!(xml.contains(&format!("\"{}\"", s.as_str())), "{s:?}");
        }
    }
}
