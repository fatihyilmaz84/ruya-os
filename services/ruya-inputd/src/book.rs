//! Controller profiles per console profile (06-input.md §7): the built-in profiles, the stored
//! ones, the global assignment, inheritance and what applies to a pad. Pure: files go through
//! `ProfileStore` (`DirStore` on the console, `MemStore` in tests and development).
//!
//! Rules:
//! - Built-in: `default` (every input to itself, the default stick settings of 06 §7) and
//!   `nintendo` (the Nintendo button layout for games: south <-> east, west <-> north). They cannot
//!   be saved over, deleted or stored.
//! - A profile without `inherits` inherits from `default`. A chain walks at most 8 `inherits`
//!   links (the one to `default` counts) and never loops; a save that would break either for the
//!   profile or for one that inherits from it is refused (`not-allowed`), a parent that does not
//!   exist too (`invalid`).
//! - At most 64 stored profiles per console profile.
//! - Every file is validated when it is loaded; a file that fails (or whose name is not its id)
//!   is left on disk, reported in the journal and not used.
//! - Deleting a profile re-parents its children to its own parent; they keep their overrides. A
//!   global assignment that named it is removed.
//! - Global assignments (RUY-545): one per slot, all controllers, a family or one device
//!   (`Slot`); each names a built-in or a global profile whose `match` names that slot. A pad takes
//!   its device's slot, else its family's, else all controllers', else `default`. Assigning or
//!   emptying a slot never touches another; a save that changes an assigned profile's `match`
//!   takes it out of its old slot. Platform and game assignments are RUY-43.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, Read, Write};
use std::path::PathBuf;

use crate::engine::{Engine, Resolved, StickSettings};
use crate::mapping::Confirm;
use crate::profile::{self, Input, Mapping, Profile, Scope, Target};
use crate::routing::Status;

pub const DEFAULT_ID: &str = "default";
pub const NINTENDO_ID: &str = "nintendo";
/// The most `inherits` links a chain may walk (06 §7).
pub const MAX_LEVELS: usize = 8;
/// The most stored profiles of one console profile.
pub const MAX_PROFILES: usize = 64;
/// The file of the assignments; not a profile id (ids start with a letter or digit).
pub const ASSIGNMENTS: &str = "_assignments.json";
/// The file of the console profile's own input settings (the Confirm button, 06 section 11.2);
/// not a profile id either.
pub const SETTINGS: &str = "_settings.json";
/// How many directory entries a load looks at.
const MAX_ENTRIES: usize = 256;

/// The files of one console profile's directory.
pub trait ProfileStore: Send {
    /// Every regular file: (name, text). A missing directory has none.
    fn read_all(&mut self, console: &str) -> io::Result<Vec<(String, String)>>;
    /// Writes a file whole (a crash leaves the old one or the new one).
    fn write(&mut self, console: &str, name: &str, text: &str) -> io::Result<()>;
    /// Removes a file; a file that is not there is no error.
    fn remove(&mut self, console: &str, name: &str) -> io::Result<()>;
}

/// `<root>/<console profile>/<file>`: the service's StateDirectory (`/var/lib/ruya-input/profiles`),
/// directories 0700, files 0600, written under a temporary name and renamed.
pub struct DirStore {
    root: PathBuf,
}

impl DirStore {
    pub fn new(root: PathBuf) -> Self {
        DirStore { root }
    }

    fn make_dir(path: &std::path::Path) -> io::Result<()> {
        let mut b = fs::DirBuilder::new();
        b.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            b.mode(0o700);
        }
        b.create(path)
    }
}

impl ProfileStore for DirStore {
    fn read_all(&mut self, console: &str) -> io::Result<Vec<(String, String)>> {
        let dir = self.root.join(console);
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        let mut out = Vec::new();
        for entry in entries.take(MAX_ENTRIES) {
            let entry = entry?;
            let Ok(name) = entry.file_name().into_string() else {
                continue;
            };
            if name.starts_with('.') || !name.ends_with(".json") {
                continue;
            }
            // Never follow a link: only regular files count.
            if !entry.file_type()?.is_file() {
                continue;
            }
            let mut text = String::new();
            let read = fs::File::open(entry.path()).and_then(|f| {
                f.take(profile::MAX_BYTES as u64 + 1)
                    .read_to_string(&mut text)
            });
            match read {
                Ok(_) => out.push((name, text)),
                // Not UTF-8, or unreadable: reported by the loader as an empty file.
                Err(_) => out.push((name, String::new())),
            }
        }
        Ok(out)
    }

    fn write(&mut self, console: &str, name: &str, text: &str) -> io::Result<()> {
        Self::make_dir(&self.root)?;
        let dir = self.root.join(console);
        Self::make_dir(&dir)?;
        let tmp = dir.join(format!(".{name}.tmp"));
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
            fs::rename(&tmp, dir.join(name))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }

    fn remove(&mut self, console: &str, name: &str) -> io::Result<()> {
        match fs::remove_file(self.root.join(console).join(name)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other,
        }
    }
}

/// Files in memory: the default store of a `Router`, and the tests'.
#[derive(Default)]
pub struct MemStore {
    pub files: BTreeMap<(String, String), String>,
    /// Every write and remove fails while true.
    pub fail: bool,
}

impl ProfileStore for MemStore {
    fn read_all(&mut self, console: &str) -> io::Result<Vec<(String, String)>> {
        Ok(self
            .files
            .iter()
            .filter(|((c, _), _)| c == console)
            .map(|((_, n), t)| (n.clone(), t.clone()))
            .collect())
    }

    fn write(&mut self, console: &str, name: &str, text: &str) -> io::Result<()> {
        if self.fail {
            return Err(io::Error::other("store refuses writes"));
        }
        self.files
            .insert((console.to_owned(), name.to_owned()), text.to_owned());
        Ok(())
    }

    fn remove(&mut self, console: &str, name: &str) -> io::Result<()> {
        if self.fail {
            return Err(io::Error::other("store refuses writes"));
        }
        self.files.remove(&(console.to_owned(), name.to_owned()));
        Ok(())
    }
}

/// One row of `ListProfiles` (the profile summary of the XML).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub id: String,
    pub name: String,
    pub scope: String,
    pub scope_id: String,
    pub inherits: String,
    pub builtin: bool,
    /// The console profile's global assignment of `global_slot` names it.
    pub assigned: bool,
    /// The slot its `match` names, as `AssignProfile`'s scope_id ("" all, "family:<f>",
    /// "device:<id>").
    pub global_slot: String,
    pub match_family: String,
    pub match_device: String,
    /// "nintendo" when the chain holds the built-in Nintendo layout, else "standard".
    pub layout: String,
    /// Buttons this profile maps differently from its parent.
    pub remapped: u32,
    /// The resolved stick settings differ from the built-in default's.
    pub left_stick_changed: bool,
    pub right_stick_changed: bool,
    /// The resolved profile does anything the built-in default does not.
    pub changed: bool,
}

/// What `SaveProfile` answers: status, the profile id, `path: message` lines.
pub type SaveAnswer = (Status, String, Vec<String>);

/// A global assignment slot (06 §7, RUY-545): all controllers, one family, one stable device id.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Slot {
    All,
    Family(String),
    Device(String),
}

impl Slot {
    /// `AssignProfile`'s scope_id: "" | "family:<f>" | "device:<id>"; `None` for anything else.
    pub fn parse(scope_id: &str) -> Option<Slot> {
        if scope_id.is_empty() {
            return Some(Slot::All);
        }
        if let Some(f) = scope_id.strip_prefix("family:") {
            return profile::valid_family(f).then(|| Slot::Family(f.to_owned()));
        }
        if let Some(d) = scope_id.strip_prefix("device:") {
            return profile::valid_device(d).then(|| Slot::Device(d.to_owned()));
        }
        None
    }

    pub fn scope_id(&self) -> String {
        match self {
            Slot::All => String::new(),
            Slot::Family(f) => format!("family:{f}"),
            Slot::Device(d) => format!("device:{d}"),
        }
    }

    /// The slot a profile's `match` names: its device, else its family, else all controllers.
    pub fn of(p: &Profile) -> Slot {
        let m = p.matches.clone().unwrap_or_default();
        match (m.device, m.family) {
            (Some(d), _) => Slot::Device(d),
            (None, Some(f)) => Slot::Family(f),
            (None, None) => Slot::All,
        }
    }

    /// The key in `_assignments.json`: "all" for all controllers, else the scope_id.
    fn key(&self) -> String {
        match self {
            Slot::All => "all".to_owned(),
            other => other.scope_id(),
        }
    }

    fn from_key(key: &str) -> Option<Slot> {
        match key {
            "all" => Some(Slot::All),
            "" => None,
            other => Slot::parse(other),
        }
    }
}

#[derive(Default)]
struct Shelf {
    profiles: BTreeMap<String, Profile>,
    /// The global assignments by slot.
    global: BTreeMap<Slot, String>,
    confirm: Confirm,
}

fn builtins() -> BTreeMap<String, Profile> {
    let swap = |from: &str, to: &str| Mapping {
        from: Input::Named(from.to_owned()),
        to: Target {
            kind: "button".to_owned(),
            code: Some(to.to_owned()),
            invert: None,
            scale: None,
        },
        mode: None,
        hold_ms: None,
        turbo_hz: None,
        threshold: None,
    };
    let default = Profile {
        id: DEFAULT_ID.to_owned(),
        name: "Default".to_owned(),
        description: Some("Every button as it is on the controller.".to_owned()),
        scope: Scope::Builtin,
        inherits: None,
        matches: None,
        output: Some("xbox".to_owned()),
        mappings: Some(Vec::new()),
        layers: None,
        chords: None,
        macros: None,
        settings: None,
    };
    let nintendo = Profile {
        id: NINTENDO_ID.to_owned(),
        name: "Nintendo layout".to_owned(),
        description: Some(
            "South and east, west and north swapped, as the labels sit on a Nintendo controller."
                .to_owned(),
        ),
        inherits: Some(DEFAULT_ID.to_owned()),
        mappings: Some(vec![
            swap("south", "east"),
            swap("east", "south"),
            swap("west", "north"),
            swap("north", "west"),
        ]),
        ..default.clone()
    };
    [default, nintendo]
        .into_iter()
        .map(|p| (p.id.clone(), p))
        .collect()
}

pub struct Book {
    store: Box<dyn ProfileStore>,
    shelves: BTreeMap<String, Shelf>,
    builtins: BTreeMap<String, Profile>,
    journal: Vec<String>,
}

impl Default for Book {
    fn default() -> Self {
        Book::new(Box::new(MemStore::default()))
    }
}

/// The chain of `id` from itself to `default`, or why it cannot be walked.
fn walk<'a>(
    id: &str,
    stored: &'a BTreeMap<String, Profile>,
    builtins: &'a BTreeMap<String, Profile>,
) -> Result<Vec<&'a Profile>, (Status, String)> {
    let mut chain = Vec::new();
    let mut seen = BTreeSet::new();
    let mut cur = id.to_owned();
    loop {
        let Some(p) = stored.get(&cur).or_else(|| builtins.get(&cur)) else {
            return Err((Status::Invalid, format!("no profile \"{cur}\"")));
        };
        seen.insert(cur.clone());
        chain.push(p);
        if cur == DEFAULT_ID {
            return Ok(chain);
        }
        let next = p.inherits.clone().unwrap_or_else(|| DEFAULT_ID.to_owned());
        if seen.contains(&next) {
            return Err((
                Status::NotAllowed,
                format!("\"{id}\" would inherit from itself through \"{next}\""),
            ));
        }
        if chain.len() > MAX_LEVELS {
            return Err((
                Status::NotAllowed,
                format!("\"{id}\" would inherit through more than {MAX_LEVELS} levels"),
            ));
        }
        cur = next;
    }
}

impl Book {
    pub fn new(store: Box<dyn ProfileStore>) -> Self {
        Book {
            store,
            shelves: BTreeMap::new(),
            builtins: builtins(),
            journal: Vec::new(),
        }
    }

    /// Journal lines since the last call (refused files, failed writes).
    pub fn take_journal(&mut self) -> Vec<String> {
        std::mem::take(&mut self.journal)
    }

    /// Loads a console profile's files once.
    fn load(&mut self, console: &str) -> Result<(), Status> {
        if self.shelves.contains_key(console) {
            return Ok(());
        }
        let files = match self.store.read_all(console) {
            Ok(f) => f,
            Err(e) => {
                self.journal
                    .push(format!("reading the profiles of {console} failed: {e}"));
                return Err(Status::Failed);
            }
        };
        let mut shelf = Shelf::default();
        // (slot, id); no slot for the one assignment of a file older than RUY-545, placed by its
        // profile's match once the profiles are read.
        let mut global: Vec<(Option<Slot>, String)> = Vec::new();
        let mut confirm = Confirm::Family;
        for (name, text) in files {
            if name == SETTINGS {
                match serde_json::from_str::<serde_json::Value>(&text) {
                    Ok(v) => match v.get("confirm_button").and_then(|m| m.as_str()) {
                        None => {}
                        Some(m) => match Confirm::parse(m) {
                            Some(c) => confirm = c,
                            None => self.journal.push(format!(
                                "{console}/{name}: confirm_button \"{m}\" is not a mode: not used"
                            )),
                        },
                    },
                    Err(_) => self
                        .journal
                        .push(format!("{console}/{name} is not a settings file: not used")),
                }
                continue;
            }
            if name == ASSIGNMENTS {
                let value = serde_json::from_str::<serde_json::Value>(&text).ok();
                match value.as_ref().map(|v| (v.is_object(), v.get("global"))) {
                    // {"global": "<id>"}: the one assignment of a file older than RUY-545.
                    Some((true, Some(serde_json::Value::String(g)))) if profile::valid_id(g) => {
                        global.push((None, g.clone()))
                    }
                    // {"global": {"all": "<id>", "family:<f>": "<id>", "device:<id>": "<id>"}}
                    Some((true, Some(serde_json::Value::Object(slots)))) => {
                        for (key, id) in slots {
                            match (Slot::from_key(key), id.as_str()) {
                                (Some(slot), Some(id)) if profile::valid_id(id) => {
                                    global.push((Some(slot), id.to_owned()))
                                }
                                _ => self.journal.push(format!(
                                    "{console}/{name}: the slot \"{key}\" is no assignment: not used"
                                )),
                            }
                        }
                    }
                    Some((true, None)) => {}
                    _ => self.journal.push(format!(
                        "{console}/{name} is not an assignment file: not used"
                    )),
                }
                continue;
            }
            match profile::parse(&text) {
                Ok(p) if format!("{}.json", p.id) != name => self.journal.push(format!(
                    "profile file {console}/{name} holds the id \"{}\": not used",
                    p.id
                )),
                Ok(p) if p.scope == Scope::Builtin || self.builtins.contains_key(&p.id) => {
                    self.journal.push(format!(
                        "profile file {console}/{name} claims a built-in profile: not used"
                    ))
                }
                Ok(p) => {
                    shelf.profiles.insert(p.id.clone(), p);
                }
                Err(errors) => self.journal.push(format!(
                    "profile file {console}/{name} refused: {}",
                    errors.join("; ")
                )),
            }
        }
        // A chain that a hand-edited file broke is not used either (the files stay).
        let broken: Vec<(String, String)> = shelf
            .profiles
            .keys()
            .filter_map(|id| {
                walk(id, &shelf.profiles, &self.builtins)
                    .err()
                    .map(|(_, why)| (id.clone(), why))
            })
            .collect();
        for (id, why) in broken {
            self.journal
                .push(format!("profile {console}/{id} not used: {why}"));
            shelf.profiles.remove(&id);
        }
        for (slot, g) in global {
            let Some(p) = shelf.profiles.get(&g).or_else(|| self.builtins.get(&g)) else {
                self.journal.push(format!(
                    "{console}: the global profile \"{g}\" does not exist"
                ));
                continue;
            };
            if !matches!(p.scope, Scope::Builtin | Scope::Global) {
                self.journal.push(format!(
                    "{console}: \"{g}\" is not a global profile: not assigned"
                ));
                continue;
            }
            // The one assignment of an older file takes the slot its profile's match names.
            let own = Slot::of(p);
            let slot = slot.unwrap_or_else(|| own.clone());
            if slot != own {
                self.journal.push(format!(
                    "{console}: \"{g}\" does not match the slot \"{}\": not assigned",
                    slot.key()
                ));
                continue;
            }
            shelf.global.insert(slot, g);
        }
        shelf.confirm = confirm;
        self.shelves.insert(console.to_owned(), shelf);
        Ok(())
    }

    /// The console profile's Confirm button (06 section 11.2): `Family` for an empty or unknown
    /// profile or when the settings cannot be read.
    pub fn confirm_button(&mut self, console: &str) -> Confirm {
        if !profile::valid_id(console) || self.load(console).is_err() {
            return Confirm::Family;
        }
        self.shelf(console).confirm
    }

    /// `SetConfirmButton`: written whole before it applies (a refused write changes nothing).
    pub fn set_confirm_button(&mut self, console: &str, mode: Confirm) -> Status {
        if let Err(status) = self.load(console) {
            return status;
        }
        let text = serde_json::json!({ "confirm_button": mode.as_str() });
        if let Err(e) = self.store.write(console, SETTINGS, &text.to_string()) {
            self.journal
                .push(format!("saving the settings of {console} failed: {e}"));
            return Status::Failed;
        }
        if let Some(shelf) = self.shelves.get_mut(console) {
            shelf.confirm = mode;
        }
        Status::Ok
    }

    fn shelf(&self, console: &str) -> &Shelf {
        static EMPTY: std::sync::OnceLock<Shelf> = std::sync::OnceLock::new();
        self.shelves
            .get(console)
            .unwrap_or_else(|| EMPTY.get_or_init(Shelf::default))
    }

    fn profile<'a>(&'a self, console: &str, id: &str) -> Option<&'a Profile> {
        self.shelf(console)
            .profiles
            .get(id)
            .or_else(|| self.builtins.get(id))
    }

    fn resolved(&self, console: &str, id: &str) -> Resolved {
        match walk(id, &self.shelf(console).profiles, &self.builtins) {
            Ok(mut chain) => {
                chain.reverse();
                Resolved::merge(&chain)
            }
            Err(_) => Resolved::default(),
        }
    }

    fn summary(&self, console: &str, p: &Profile) -> Summary {
        let shelf = self.shelf(console);
        let chain: Vec<String> = walk(&p.id, &shelf.profiles, &self.builtins)
            .map(|c| c.iter().map(|p| p.id.clone()).collect())
            .unwrap_or_default();
        let resolved = self.resolved(console, &p.id);
        let engine = Engine::compile(&resolved);
        let parent = match &p.scope {
            Scope::Builtin if p.id == DEFAULT_ID => Engine::default(),
            _ => Engine::compile(
                &self.resolved(console, p.inherits.as_deref().unwrap_or(DEFAULT_ID)),
            ),
        };
        let m = p.matches.clone().unwrap_or_default();
        let slot = Slot::of(p);
        Summary {
            id: p.id.clone(),
            name: p.name.clone(),
            scope: p.scope.kind().to_owned(),
            scope_id: p.scope.scope_id().to_owned(),
            inherits: p.inherits.clone().unwrap_or_default(),
            builtin: p.scope == Scope::Builtin,
            assigned: shelf.global.get(&slot) == Some(&p.id),
            global_slot: slot.scope_id(),
            match_family: m.family.unwrap_or_default(),
            match_device: m.device.unwrap_or_default(),
            layout: if chain.iter().any(|id| id == NINTENDO_ID) {
                "nintendo"
            } else {
                "standard"
            }
            .to_owned(),
            remapped: engine.buttons_differing(&parent) as u32,
            left_stick_changed: resolved.left != StickSettings::default(),
            right_stick_changed: resolved.right != StickSettings::default(),
            changed: engine != Engine::default(),
        }
    }

    /// `ListProfiles`: the built-ins, then the stored profiles by id.
    pub fn list(&mut self, console: &str) -> Result<Vec<Summary>, Status> {
        self.load(console)?;
        let shelf = self.shelf(console);
        Ok(self
            .builtins
            .values()
            .chain(shelf.profiles.values())
            .map(|p| self.summary(console, p))
            .collect())
    }

    /// `GetProfile`: the profile as stored (only what it sets).
    pub fn get(&mut self, console: &str, id: &str) -> Result<String, Status> {
        self.load(console)?;
        self.profile(console, id)
            .map(Profile::to_json)
            .ok_or(Status::UnknownProfile)
    }

    /// `ValidateProfile`: the file on its own (its parent is checked at `SaveProfile`).
    pub fn validate(text: &str) -> (Status, Vec<String>) {
        match profile::parse(text) {
            Ok(_) => (Status::Ok, Vec::new()),
            Err(errors) => (Status::Invalid, errors),
        }
    }

    /// `SaveProfile`: creates or replaces a stored profile.
    pub fn save(&mut self, console: &str, text: &str) -> SaveAnswer {
        let refuse = |status, id: &str, line: String| (status, id.to_owned(), vec![line]);
        let p = match profile::parse(text) {
            Ok(p) => p,
            Err(errors) => return (Status::Invalid, String::new(), errors),
        };
        if let Err(status) = self.load(console) {
            return (status, String::new(), Vec::new());
        }
        let id = p.id.clone();
        if self.builtins.contains_key(&id) {
            return refuse(
                Status::NotAllowed,
                &id,
                format!("/id: \"{id}\" is a built-in profile"),
            );
        }
        if p.scope == Scope::Builtin {
            return refuse(
                Status::NotAllowed,
                &id,
                "/scope: only the console has built-in profiles".to_owned(),
            );
        }
        let shelf = self.shelf(console);
        if !shelf.profiles.contains_key(&id) && shelf.profiles.len() >= MAX_PROFILES {
            return refuse(
                Status::NotAllowed,
                &id,
                format!("/: at most {MAX_PROFILES} profiles per console profile"),
            );
        }
        if let Some(parent) = &p.inherits {
            if parent != &id && self.profile(console, parent).is_none() {
                return refuse(
                    Status::Invalid,
                    &id,
                    format!("/inherits: no profile \"{parent}\""),
                );
            }
        }
        // The chains with the new profile in place: its own, and every profile's that inherits.
        let mut trial = shelf.profiles.clone();
        trial.insert(id.clone(), p.clone());
        for other in trial.keys() {
            if let Err((status, why)) = walk(other, &trial, &self.builtins) {
                return refuse(status, &id, format!("/inherits: {why}"));
            }
        }
        if let Err(e) = self
            .store
            .write(console, &format!("{id}.json"), &p.to_json())
        {
            self.journal
                .push(format!("saving profile {console}/{id} failed: {e}"));
            return (Status::Failed, id, Vec::new());
        }
        // An assigned profile whose match now names another slot leaves its old one (the file is
        // written; an assignment that cannot be written is inert, as a mismatched slot never
        // applies, and is dropped at the next load).
        let own = Slot::of(&p);
        let stale: Vec<Slot> = self
            .shelf(console)
            .global
            .iter()
            .filter(|(slot, g)| **g == id && **slot != own)
            .map(|(slot, _)| slot.clone())
            .collect();
        if let Some(shelf) = self.shelves.get_mut(console) {
            shelf.profiles.insert(id.clone(), p);
        }
        if !stale.is_empty() {
            let mut global = self.shelf(console).global.clone();
            for slot in stale {
                global.remove(&slot);
            }
            self.write_assignments(console, global);
        }
        (Status::Ok, id, Vec::new())
    }

    /// `DeleteProfile`.
    pub fn delete(&mut self, console: &str, id: &str) -> Status {
        if let Err(status) = self.load(console) {
            return status;
        }
        if self.builtins.contains_key(id) {
            return Status::NotAllowed;
        }
        let Some(gone) = self.shelf(console).profiles.get(id).cloned() else {
            return Status::UnknownProfile;
        };
        // Children first: they inherit from its parent now and keep their overrides.
        let children: Vec<Profile> = self
            .shelf(console)
            .profiles
            .values()
            .filter(|p| p.inherits.as_deref() == Some(id))
            .cloned()
            .collect();
        for mut child in children {
            child.inherits = gone.inherits.clone();
            if let Err(e) =
                self.store
                    .write(console, &format!("{}.json", child.id), &child.to_json())
            {
                self.journal
                    .push(format!("re-parenting {console}/{} failed: {e}", child.id));
                return Status::Failed;
            }
            if let Some(shelf) = self.shelves.get_mut(console) {
                shelf.profiles.insert(child.id.clone(), child);
            }
        }
        let mut global = self.shelf(console).global.clone();
        let before = global.len();
        global.retain(|_, g| g != id);
        if global.len() != before {
            let status = self.write_assignments(console, global);
            if status != Status::Ok {
                return status;
            }
        }
        if let Err(e) = self.store.remove(console, &format!("{id}.json")) {
            self.journal
                .push(format!("deleting profile {console}/{id} failed: {e}"));
            return Status::Failed;
        }
        if let Some(shelf) = self.shelves.get_mut(console) {
            shelf.profiles.remove(id);
        }
        Status::Ok
    }

    /// `{"global": {"all": "<id>", "family:<f>": "<id>", "device:<id>": "<id>"}}`, written whole
    /// before it applies.
    fn write_assignments(&mut self, console: &str, global: BTreeMap<Slot, String>) -> Status {
        let slots: serde_json::Map<String, serde_json::Value> = global
            .iter()
            .map(|(slot, g)| (slot.key(), serde_json::Value::from(g.as_str())))
            .collect();
        let text = serde_json::json!({ "global": slots });
        if let Err(e) = self.store.write(console, ASSIGNMENTS, &text.to_string()) {
            self.journal
                .push(format!("saving the assignments of {console} failed: {e}"));
            return Status::Failed;
        }
        if let Some(shelf) = self.shelves.get_mut(console) {
            shelf.global = global;
        }
        Status::Ok
    }

    /// `AssignProfile`; only the global scope today (platform and game: RUY-43). One slot at a
    /// time (`scope_id`, `Slot::parse`); the profile's match must name that slot.
    pub fn assign(&mut self, console: &str, scope: &str, scope_id: &str, id: &str) -> Status {
        if scope != "global" {
            return Status::Invalid;
        }
        let Some(slot) = Slot::parse(scope_id) else {
            return Status::Invalid;
        };
        if let Err(status) = self.load(console) {
            return status;
        }
        let mut global = self.shelf(console).global.clone();
        if id.is_empty() {
            global.remove(&slot);
            return self.write_assignments(console, global);
        }
        match self.profile(console, id) {
            None => Status::UnknownProfile,
            Some(p) if !matches!(p.scope, Scope::Builtin | Scope::Global) => Status::Invalid,
            Some(p) if Slot::of(p) != slot => Status::Invalid,
            Some(_) => {
                global.insert(slot, id.to_owned());
                self.write_assignments(console, global)
            }
        }
    }

    /// The profile that applies to a pad (`family`, stable id `device`; "" for none): the one
    /// assigned to its device's slot, else its family's, else all controllers', else `default`.
    /// A slot's profile counts only while its match names that slot and fits the pad.
    fn applying(&self, console: &str, family: &str, device: &str) -> String {
        let shelf = self.shelf(console);
        let fits = |p: &Profile| match &p.matches {
            None => true,
            Some(m) => {
                m.family.as_deref().map_or(true, |f| f == family)
                    && m.device.as_deref().map_or(true, |d| d == device)
            }
        };
        let mut slots = Vec::with_capacity(3);
        if !device.is_empty() {
            slots.push(Slot::Device(device.to_owned()));
        }
        if !family.is_empty() {
            slots.push(Slot::Family(family.to_owned()));
        }
        slots.push(Slot::All);
        slots
            .into_iter()
            .find_map(|slot| {
                shelf
                    .global
                    .get(&slot)
                    .and_then(|g| self.profile(console, g))
                    .filter(|p| Slot::of(p) == slot && fits(p))
                    .map(|p| p.id.clone())
            })
            .unwrap_or_else(|| DEFAULT_ID.to_owned())
    }

    /// `GetEffectiveProfile`: the merged profile as one document and its chain, most specific
    /// first.
    pub fn effective(
        &mut self,
        console: &str,
        family: &str,
        device: &str,
    ) -> Result<(String, Vec<String>), Status> {
        self.load(console)?;
        let id = self.applying(console, family, device);
        let shelf = self.shelf(console);
        let chain = walk(&id, &shelf.profiles, &self.builtins).map_err(|_| Status::Failed)?;
        let ids = chain.iter().map(|p| p.id.clone()).collect();
        let top = chain[0].clone();
        let flat = self.resolved(console, &id).flatten(&top);
        Ok((flat.to_json(), ids))
    }

    /// The engine for a pad of `console` (the default one when the profiles cannot be read).
    pub fn engine_for(&mut self, console: &str, family: &str, device: &str) -> Engine {
        if self.load(console).is_err() {
            return Engine::default();
        }
        let id = self.applying(console, family, device);
        Engine::compile(&self.resolved(console, &id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(id: &str, extra: &str) -> String {
        let extra = if extra.is_empty() {
            String::new()
        } else {
            format!(",{extra}")
        };
        format!(
            r#"{{"schema_version":1,"id":"{id}","name":"{id}","scope":{{"type":"global"}}{extra}}}"#
        )
    }

    fn book() -> Book {
        Book::default()
    }

    fn ids(b: &mut Book) -> Vec<String> {
        b.list("p1").unwrap().into_iter().map(|s| s.id).collect()
    }

    #[test]
    fn the_builtins_are_listed_and_cannot_be_changed() {
        let mut b = book();
        let list = b.list("p1").unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!((list[0].id.as_str(), list[0].builtin), ("default", true));
        assert_eq!(list[1].id, "nintendo");
        assert_eq!(list[1].layout, "nintendo");
        assert_eq!(list[1].remapped, 4);
        assert!(list[1].changed && !list[0].changed);
        assert_eq!(b.delete("p1", "default"), Status::NotAllowed);
        assert_eq!(b.delete("p1", "nintendo"), Status::NotAllowed);
        let (status, _, errors) = b.save("p1", &profile("default", ""));
        assert_eq!(status, Status::NotAllowed);
        assert_eq!(errors, vec!["/id: \"default\" is a built-in profile"]);
        let builtin_scope = profile("mine", "").replace("global", "builtin");
        assert_eq!(b.save("p1", &builtin_scope).0, Status::NotAllowed);
        // The built-ins are valid profiles of the public format.
        for id in ["default", "nintendo"] {
            let text = b.get("p1", id).unwrap();
            assert_eq!(Book::validate(&text), (Status::Ok, vec![]), "{id}");
        }
    }

    #[test]
    fn save_get_and_delete() {
        let mut b = book();
        let text = profile(
            "mine",
            r#""mappings":[{"from":"south","to":{"type":"button","code":"west"}}]"#,
        );
        assert_eq!(b.save("p1", &text), (Status::Ok, "mine".into(), vec![]));
        assert_eq!(ids(&mut b), ["default", "nintendo", "mine"]);
        let stored = b.get("p1", "mine").unwrap();
        assert_eq!(
            profile::parse(&stored).unwrap(),
            profile::parse(&text).unwrap()
        );
        assert_eq!(b.get("p1", "nope"), Err(Status::UnknownProfile));
        assert!(
            b.list("p2").unwrap().iter().all(|s| s.id != "mine"),
            "per console profile"
        );
        assert_eq!(b.delete("p1", "mine"), Status::Ok);
        assert_eq!(b.delete("p1", "mine"), Status::UnknownProfile);
        assert_eq!(ids(&mut b), ["default", "nintendo"]);
    }

    #[test]
    fn a_bad_file_is_refused_with_its_reasons() {
        let mut b = book();
        let (status, id, errors) = b.save(
            "p1",
            r#"{"schema_version":1,"id":"x","name":"","scope":{"type":"global"},"script":1}"#,
        );
        assert_eq!((status, id.as_str()), (Status::Invalid, ""));
        assert!(
            errors.iter().any(|e| e.starts_with("/name: ")),
            "{errors:?}"
        );
        assert!(
            errors.iter().any(|e| e.contains("unknown field script")),
            "{errors:?}"
        );
        let (status, errors) = Book::validate(&"x".repeat(profile::MAX_BYTES + 1));
        assert_eq!(status, Status::Invalid);
        assert!(errors[0].contains("larger than 65536 bytes"));
    }

    #[test]
    fn inheritance_needs_a_parent_and_refuses_cycles_and_depth() {
        let mut b = book();
        let (status, _, errors) = b.save("p1", &profile("a", r#""inherits":"ghost""#));
        assert_eq!(status, Status::Invalid);
        assert_eq!(errors, vec!["/inherits: no profile \"ghost\""]);
        assert_eq!(
            b.save("p1", &profile("a", r#""inherits":"nintendo""#)).0,
            Status::Ok
        );
        assert_eq!(
            b.save("p1", &profile("b", r#""inherits":"a""#)).0,
            Status::Ok
        );
        // a -> b -> a
        let (status, _, errors) = b.save("p1", &profile("a", r#""inherits":"b""#));
        assert_eq!(status, Status::NotAllowed);
        assert!(
            errors[0].contains("would inherit from itself"),
            "{errors:?}"
        );
        // Eight links are fine: c1 -> c2 -> ... -> c8 -> default.
        let mut b = book();
        for n in (1..=8).rev() {
            let extra = if n == 8 {
                String::new()
            } else {
                format!(r#""inherits":"c{}""#, n + 1)
            };
            assert_eq!(
                b.save("p1", &profile(&format!("c{n}"), &extra)).0,
                Status::Ok,
                "c{n}"
            );
        }
        // A ninth on top is refused...
        let (status, _, errors) = b.save("p1", &profile("c0", r#""inherits":"c1""#));
        assert_eq!(status, Status::NotAllowed);
        assert!(errors[0].contains("more than 8 levels"), "{errors:?}");
        // ... and so is a change below that would push a descendant over.
        assert_eq!(
            b.save("p1", &profile("c8", r#""inherits":"nintendo""#)).0,
            Status::NotAllowed
        );
    }

    #[test]
    fn deleting_a_parent_reparents_its_children() {
        let mut b = book();
        b.save(
            "p1",
            &profile(
                "base",
                r#""inherits":"nintendo","settings":{"trigger_threshold":0.2}"#,
            ),
        );
        b.save("p1", &profile("kid", r#""inherits":"base","mappings":[{"from":"l1","to":{"type":"button","code":"r1"}}]"#));
        assert_eq!(b.delete("p1", "base"), Status::Ok);
        let kid = profile::parse(&b.get("p1", "kid").unwrap()).unwrap();
        assert_eq!(kid.inherits.as_deref(), Some("nintendo"));
        assert_eq!(kid.mappings.unwrap().len(), 1, "keeps its overrides");
        let s = b
            .list("p1")
            .unwrap()
            .into_iter()
            .find(|s| s.id == "kid")
            .unwrap();
        assert_eq!(s.layout, "nintendo");
    }

    #[test]
    fn the_global_assignment_applies_by_match() {
        let mut b = book();
        let swapped = r#""mappings":[{"from":"south","to":{"type":"button","code":"east"}}]"#;
        b.save(
            "p1",
            &profile(
                "ps",
                &format!(r#"{swapped},"match":{{"family":"playstation"}}"#),
            ),
        );
        let pad = |b: &mut Book, family: &str, device: &str| b.engine_for("p1", family, device);
        assert_eq!(
            pad(&mut b, "playstation", "x"),
            Engine::default(),
            "not assigned yet"
        );
        assert_eq!(
            b.assign("p1", "global", "", "ps"),
            Status::Invalid,
            "its match names the family's slot, not all controllers'"
        );
        assert_eq!(
            b.assign("p1", "global", "family:playstation", "ps"),
            Status::Ok
        );
        assert_ne!(pad(&mut b, "playstation", "x"), Engine::default());
        assert_eq!(
            pad(&mut b, "xbox", "x"),
            Engine::default(),
            "another family"
        );
        let (json, chain) = b.effective("p1", "playstation", "x").unwrap();
        assert_eq!(chain, ["ps", "default"]);
        assert!(json.contains("\"inner_deadzone\": 0.08"), "{json}");
        let (_, chain) = b.effective("p1", "xbox", "x").unwrap();
        assert_eq!(chain, ["default"]);
        // One device.
        b.save(
            "p1",
            &profile(
                "one",
                &format!(r#"{swapped},"match":{{"device":"usb-1-2-abc"}}"#),
            ),
        );
        assert_eq!(
            b.assign("p1", "global", "device:usb-1-2-abc", "one"),
            Status::Ok
        );
        assert_ne!(pad(&mut b, "xbox", "usb-1-2-abc"), Engine::default());
        assert_eq!(pad(&mut b, "xbox", "usb-1-2-abd"), Engine::default());
        // A built-in as the global profile of all controllers; "" empties that slot.
        assert_eq!(b.assign("p1", "global", "", "nintendo"), Status::Ok);
        assert!(b
            .list("p1")
            .unwrap()
            .iter()
            .any(|s| s.id == "nintendo" && s.assigned && s.global_slot.is_empty()));
        assert_eq!(b.assign("p1", "global", "", ""), Status::Ok);
        assert_eq!(
            b.assign("p1", "global", "family:playstation", ""),
            Status::Ok
        );
        assert_eq!(
            b.assign("p1", "global", "device:usb-1-2-abc", ""),
            Status::Ok
        );
        assert!(b.list("p1").unwrap().iter().all(|s| !s.assigned));
        // Refusals.
        assert_eq!(b.assign("p1", "global", "", "nope"), Status::UnknownProfile);
        assert_eq!(b.assign("p1", "global", "x", "ps"), Status::Invalid);
        assert_eq!(
            b.assign("p1", "game", "org.example.Game", "ps"),
            Status::Invalid
        );
        let game = r#"{"schema_version":1,"id":"g","name":"G","scope":{"type":"game","game_id":"org.example.Game"}}"#;
        assert_eq!(b.save("p1", game).0, Status::Ok);
        assert_eq!(b.assign("p1", "global", "", "g"), Status::Invalid);
        // Deleting the assigned profile removes the assignment.
        b.assign("p1", "global", "family:playstation", "ps");
        b.delete("p1", "ps");
        assert_eq!(
            b.effective("p1", "playstation", "x").unwrap().1,
            ["default"]
        );
    }

    /// The files of p1 as the store has them, by name.
    fn files(b: &mut Book) -> BTreeMap<String, String> {
        b.store.read_all("p1").unwrap().into_iter().collect()
    }

    /// The engine a profile compiles to on its own (what a pad that it applies to gets).
    fn engine_of(b: &mut Book, id: &str) -> Engine {
        b.load("p1").unwrap();
        Engine::compile(&b.resolved("p1", id))
    }

    fn swap_to(id: &str, to: &str, matches: &str) -> String {
        let m = if matches.is_empty() {
            String::new()
        } else {
            format!(r#","match":{matches}"#)
        };
        profile(
            id,
            &format!(
                r#""mappings":[{{"from":"south","to":{{"type":"button","code":"{to}"}}}}]{m}"#
            ),
        )
    }

    // RUY-545: pad A (a DualSense) has its own profile, pad B (a Nintendo pad) its family's; each
    // pad gets its own, and emptying one slot leaves the other.
    #[test]
    fn each_pad_takes_the_profile_of_its_most_specific_slot() {
        const A: &str = "bluetooth-054c-0ce6-3f2a9c41d0b7";
        const B: &str = "bluetooth-057e-2009-b7c0e1f2a3d4";
        let mut b = book();
        assert_eq!(
            b.save(
                "p1",
                &swap_to("a", "east", &format!(r#"{{"device":"{A}"}}"#))
            )
            .0,
            Status::Ok
        );
        assert_eq!(
            b.save("p1", &swap_to("n", "west", r#"{"family":"nintendo"}"#))
                .0,
            Status::Ok
        );
        assert_eq!(b.save("p1", &swap_to("every", "north", "")).0, Status::Ok);
        assert_eq!(
            b.assign("p1", "global", &format!("device:{A}"), "a"),
            Status::Ok
        );
        assert_eq!(b.assign("p1", "global", "family:nintendo", "n"), Status::Ok);
        let (ea, en) = (engine_of(&mut b, "a"), engine_of(&mut b, "n"));
        assert_ne!(ea, en);
        assert_eq!(b.engine_for("p1", "playstation", A), ea, "A: its device's");
        assert_eq!(b.engine_for("p1", "nintendo", B), en, "B: its family's");
        assert_eq!(
            b.engine_for("p1", "nintendo", A),
            ea,
            "the device's slot over the family's"
        );
        assert_eq!(
            b.engine_for("p1", "xbox", "usb-045e-0b12-8e01c2d4a9f3"),
            Engine::default(),
            "a third pad: nothing applies"
        );
        assert_eq!(
            b.effective("p1", "playstation", A).unwrap().1,
            ["a", "default"]
        );
        assert_eq!(
            b.effective("p1", "nintendo", B).unwrap().1,
            ["n", "default"]
        );
        // All controllers' slot is under both.
        assert_eq!(b.assign("p1", "global", "", "every"), Status::Ok);
        let every = engine_of(&mut b, "every");
        assert_eq!(
            b.engine_for("p1", "xbox", "usb-045e-0b12-8e01c2d4a9f3"),
            every
        );
        assert_eq!(b.engine_for("p1", "playstation", A), ea);
        assert_eq!(b.engine_for("p1", "nintendo", B), en);
        let slots = |b: &mut Book| -> Vec<(String, String)> {
            b.list("p1")
                .unwrap()
                .into_iter()
                .filter(|s| s.assigned)
                .map(|s| (s.global_slot, s.id))
                .collect()
        };
        assert_eq!(
            slots(&mut b),
            [
                (format!("device:{A}"), "a".to_owned()),
                ("".to_owned(), "every".to_owned()),
                ("family:nintendo".to_owned(), "n".to_owned())
            ]
        );
        // Emptying the family's slot leaves the device's and all controllers'.
        assert_eq!(b.assign("p1", "global", "family:nintendo", ""), Status::Ok);
        assert_eq!(b.engine_for("p1", "playstation", A), ea, "A keeps its own");
        assert_eq!(b.engine_for("p1", "nintendo", B), every, "B falls to all");
        assert_eq!(b.assign("p1", "global", "", ""), Status::Ok);
        assert_eq!(b.engine_for("p1", "nintendo", B), Engine::default());
        assert_eq!(b.engine_for("p1", "playstation", A), ea);
        // Assigning one slot replaces only that slot's profile.
        assert_eq!(
            b.save("p1", &swap_to("n2", "north", r#"{"family":"nintendo"}"#))
                .0,
            Status::Ok
        );
        assert_eq!(b.assign("p1", "global", "family:nintendo", "n"), Status::Ok);
        assert_eq!(
            b.assign("p1", "global", "family:nintendo", "n2"),
            Status::Ok
        );
        assert_eq!(b.engine_for("p1", "nintendo", B), engine_of(&mut b, "n2"));
        assert_eq!(b.engine_for("p1", "playstation", A), ea);
    }

    #[test]
    fn a_slot_takes_only_a_profile_whose_match_names_it() {
        const A: &str = "usb-1-2-abc";
        let mut b = book();
        b.save(
            "p1",
            &swap_to("a", "east", &format!(r#"{{"device":"{A}"}}"#)),
        );
        b.save("p1", &swap_to("n", "west", r#"{"family":"nintendo"}"#));
        b.save("p1", &swap_to("plain", "west", ""));
        b.save(
            "p1",
            &swap_to(
                "both",
                "west",
                &format!(r#"{{"family":"xbox","device":"{A}"}}"#),
            ),
        );
        for (scope_id, id) in [
            ("", "a"),
            ("", "n"),
            ("family:xbox", "n"),
            ("family:nintendo", "a"),
            ("family:nintendo", "plain"),
            (&*format!("device:{A}"), "n"),
            ("device:usb-1-2-abd", "a"),
            ("family:nintendo", "nintendo"),
            ("family:xbox", "both"),
        ] {
            assert_eq!(
                b.assign("p1", "global", scope_id, id),
                Status::Invalid,
                "{id} in \"{scope_id}\""
            );
        }
        for scope_id in [
            "all",
            "family:",
            "family:sega",
            "device:",
            "device:USB",
            "game:x",
            "family:nintendo ",
        ] {
            assert_eq!(
                b.assign("p1", "global", scope_id, ""),
                Status::Invalid,
                "\"{scope_id}\" is no slot"
            );
        }
        assert_eq!(
            b.assign("p1", "global", &format!("device:{A}"), "both"),
            Status::Ok
        );
        assert_eq!(
            b.engine_for("p1", "nintendo", A),
            Engine::default(),
            "a device's profile with another family's match does not fit"
        );
        assert!(b
            .list("p1")
            .unwrap()
            .iter()
            .all(|s| s.id == "both" || !s.assigned));
    }

    #[test]
    fn a_save_that_changes_the_match_takes_the_profile_out_of_its_slot() {
        let mut b = book();
        b.save("p1", &swap_to("n", "west", r#"{"family":"nintendo"}"#));
        b.save("p1", &swap_to("every", "north", ""));
        assert_eq!(b.assign("p1", "global", "family:nintendo", "n"), Status::Ok);
        assert_eq!(b.assign("p1", "global", "", "every"), Status::Ok);
        let every = engine_of(&mut b, "every");
        // The same profile for PlayStation pads now: it leaves Nintendo's slot, takes no other.
        assert_eq!(
            b.save("p1", &swap_to("n", "west", r#"{"family":"playstation"}"#))
                .0,
            Status::Ok
        );
        assert_eq!(b.engine_for("p1", "nintendo", "x"), every);
        assert_eq!(
            b.engine_for("p1", "playstation", "x"),
            every,
            "not assigned"
        );
        let n = b
            .list("p1")
            .unwrap()
            .into_iter()
            .find(|s| s.id == "n")
            .unwrap();
        assert_eq!(
            (n.assigned, n.global_slot.as_str()),
            (false, "family:playstation")
        );
        // The file says so too.
        let mut again = Book::new(Box::new(MemStore {
            files: files(&mut b)
                .into_iter()
                .map(|(name, text)| (("p1".to_owned(), name), text))
                .collect(),
            ..MemStore::default()
        }));
        assert_eq!(again.engine_for("p1", "nintendo", "x"), every);
        assert!(again.take_journal().is_empty());
        // A save that keeps the match keeps the slot.
        assert_eq!(b.save("p1", &swap_to("every", "south", "")).0, Status::Ok);
        assert!(b
            .list("p1")
            .unwrap()
            .iter()
            .any(|s| s.id == "every" && s.assigned));
    }

    // The Dell's p1 before RUY-545: one assignment, `controls`, whose match names Nintendo pads.
    #[test]
    fn an_assignment_file_from_before_the_slots_still_loads() {
        let mut store = MemStore::default();
        let mut put = |name: &str, text: &str| {
            store.files.insert(("p1".into(), name.into()), text.into());
        };
        put(
            "controls.json",
            r#"{"id":"controls","match":{"family":"nintendo"},"name":"Controls in games","schema_version":1,"scope":{"type":"global"},"settings":{"left_stick":{"inner_deadzone":0.2}}}"#,
        );
        put(ASSIGNMENTS, r#"{"global":"controls"}"#);
        let mut b = Book::new(Box::new(store));
        let controls = engine_of(&mut b, "controls");
        assert_ne!(controls, Engine::default());
        assert_eq!(
            b.engine_for("p1", "nintendo", "bluetooth-057e-2009-b7c0e1f2a3d4"),
            controls,
            "the Wii U Pro: the family's slot"
        );
        assert_eq!(
            b.engine_for("p1", "playstation", "bluetooth-054c-0ce6-3f2a9c41d0b7"),
            Engine::default(),
            "the DualSense"
        );
        let s = b
            .list("p1")
            .unwrap()
            .into_iter()
            .find(|s| s.id == "controls")
            .unwrap();
        assert!(s.assigned);
        assert_eq!(s.global_slot, "family:nintendo");
        assert!(b.take_journal().is_empty());
        // One without a match: all controllers'; a built-in too.
        for (file, id) in [
            (r#"{"global":"plain"}"#, "plain"),
            (r#"{"global":"nintendo"}"#, "nintendo"),
        ] {
            let mut store = MemStore::default();
            store
                .files
                .insert(("p1".into(), "plain.json".into()), profile("plain", ""));
            store
                .files
                .insert(("p1".into(), ASSIGNMENTS.into()), file.into());
            let mut b = Book::new(Box::new(store));
            let s = b
                .list("p1")
                .unwrap()
                .into_iter()
                .find(|s| s.id == id)
                .unwrap();
            assert!(s.assigned && s.global_slot.is_empty(), "{file}");
        }
        // The next assignment writes the slots.
        assert_eq!(b.assign("p1", "global", "", "nintendo"), Status::Ok);
        assert_eq!(
            files(&mut b)[ASSIGNMENTS],
            r#"{"global":{"all":"nintendo","family:nintendo":"controls"}}"#
        );
    }

    #[test]
    fn a_slot_file_with_bad_entries_keeps_the_good_ones() {
        let mut store = MemStore::default();
        store.files.insert(
            ("p1".into(), "n.json".into()),
            swap_to("n", "west", r#"{"family":"nintendo"}"#),
        );
        store
            .files
            .insert(("p1".into(), "plain.json".into()), profile("plain", ""));
        store.files.insert(
            ("p1".into(), ASSIGNMENTS.into()),
            r#"{"global":{"family:nintendo":"n","all":"n","family:sega":"plain","device:x":"ghost","":"plain","family:xbox":7}}"#
                .into(),
        );
        let mut b = Book::new(Box::new(store));
        assert_eq!(b.engine_for("p1", "nintendo", "x"), engine_of(&mut b, "n"));
        assert_eq!(b.engine_for("p1", "xbox", "y"), Engine::default());
        let journal = b.take_journal().join("\n");
        for needle in [
            "\"n\" does not match the slot \"all\"",
            "the slot \"family:sega\" is no assignment",
            "the slot \"\" is no assignment",
            "the slot \"family:xbox\" is no assignment",
            "the global profile \"ghost\" does not exist",
        ] {
            assert!(journal.contains(needle), "{needle:?} not in {journal}");
        }
    }

    #[test]
    fn the_summary_tells_what_changed() {
        let mut b = book();
        b.save("p1", &profile("m", r#""inherits":"nintendo","mappings":[{"from":"west","to":{"type":"button","code":"south"}},{"from":"l1","to":{"type":"button","code":"l1"}}],"settings":{"right_stick":{"curve":"precise"}}"#));
        let s = b
            .list("p1")
            .unwrap()
            .into_iter()
            .find(|s| s.id == "m")
            .unwrap();
        assert_eq!(s.layout, "nintendo");
        assert_eq!(
            s.remapped, 1,
            "west differs from the layout; l1 to itself does not"
        );
        assert!(!s.left_stick_changed && s.right_stick_changed && s.changed);
        assert_eq!(s.inherits, "nintendo");
        b.save("p1", &profile("plain", ""));
        let s = b
            .list("p1")
            .unwrap()
            .into_iter()
            .find(|s| s.id == "plain")
            .unwrap();
        assert!(!s.changed && s.remapped == 0 && s.layout == "standard");
    }

    #[test]
    fn at_most_64_profiles_per_console_profile() {
        let mut b = book();
        for n in 0..MAX_PROFILES {
            assert_eq!(b.save("p1", &profile(&format!("p{n}"), "")).0, Status::Ok);
        }
        let (status, _, errors) = b.save("p1", &profile("one-more", ""));
        assert_eq!(status, Status::NotAllowed);
        assert!(errors[0].contains("at most 64"));
        assert_eq!(
            b.save("p1", &profile("p3", r#""description":"again""#)).0,
            Status::Ok,
            "replacing is fine"
        );
    }

    #[test]
    fn files_are_validated_on_load_and_bad_ones_are_not_used() {
        let mut store = MemStore::default();
        let mut put = |name: &str, text: &str| {
            store.files.insert(("p1".into(), name.into()), text.into());
        };
        put("good.json", &profile("good", r#""inherits":"nintendo""#));
        put("bad.json", r#"{"schema_version":1,"id":"bad"}"#);
        put("other.json", &profile("renamed", ""));
        put("nintendo.json", &profile("nintendo", ""));
        put("loop1.json", &profile("loop1", r#""inherits":"loop2""#));
        put("loop2.json", &profile("loop2", r#""inherits":"loop1""#));
        put("huge.json", &" ".repeat(profile::MAX_BYTES + 1));
        put(ASSIGNMENTS, r#"{"global":"good"}"#);
        let mut b = Book::new(Box::new(store));
        assert_eq!(ids(&mut b), ["default", "nintendo", "good"]);
        assert!(b
            .list("p1")
            .unwrap()
            .iter()
            .any(|s| s.id == "good" && s.assigned));
        let journal = b.take_journal().join("\n");
        for needle in [
            "bad.json refused: /: \"name\" is required",
            "other.json holds the id \"renamed\"",
            "nintendo.json claims a built-in profile",
            "loop1 not used",
            "huge.json refused: /: 65537 bytes, larger than 65536",
        ] {
            assert!(journal.contains(needle), "{needle:?} not in {journal}");
        }
    }

    #[test]
    fn a_failed_write_changes_nothing() {
        let store = MemStore {
            fail: true,
            ..MemStore::default()
        };
        let mut b = Book::new(Box::new(store));
        assert_eq!(b.save("p1", &profile("x", "")).0, Status::Failed);
        assert_eq!(ids(&mut b), ["default", "nintendo"]);
        assert_eq!(b.assign("p1", "global", "", "nintendo"), Status::Failed);
        assert!(b.list("p1").unwrap().iter().all(|s| !s.assigned));
        assert!(b.take_journal()[0].contains("saving profile p1/x failed"));
    }

    #[test]
    fn the_directory_store_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("profiles");
        let mut b = Book::new(Box::new(DirStore::new(root.clone())));
        assert_eq!(
            b.save("p1", &profile("mine", r#""inherits":"nintendo""#)).0,
            Status::Ok
        );
        assert_eq!(b.assign("p1", "global", "", "mine"), Status::Ok);
        assert!(root.join("p1").join("mine.json").is_file());
        assert!(!root.join("p1").join(".mine.json.tmp").exists());
        let mut again = Book::new(Box::new(DirStore::new(root.clone())));
        let s = again.list("p1").unwrap();
        assert!(s
            .iter()
            .any(|s| s.id == "mine" && s.assigned && s.layout == "nintendo"));
        assert_eq!(again.delete("p1", "mine"), Status::Ok);
        assert!(!root.join("p1").join("mine.json").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |p: &std::path::Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&root.join("p1")), 0o700);
            assert_eq!(mode(&root.join("p1").join(ASSIGNMENTS)), 0o600);
        }
    }

    #[cfg(unix)]
    #[test]
    fn the_directory_store_never_follows_a_link() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("profiles");
        fs::create_dir_all(root.join("p1")).unwrap();
        let outside = dir.path().join("outside.json");
        fs::write(&outside, profile("linked", "")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("p1").join("linked.json")).unwrap();
        let mut b = Book::new(Box::new(DirStore::new(root)));
        assert_eq!(ids(&mut b), ["default", "nintendo"]);
    }
}
