//! Where the play ledger lives (T-247): `/var/lib/ruya-session/usage/<profile>/` as root-only
//! files. One file per profile, `ledger.tsv`, with a line per finished session and per rolled-up
//! day and item: `S` and `R` for a Flatpak app's item (the form of T-247, which an older image
//! reads), `S2` and `R2` with the item for any other (a Steam game, RUY-1051); a session is
//! appended with one `write` of a whole line (O_APPEND), the rolled-up form is rewritten atomically
//! (temporary file, `fsync`, rename). A running session is a small file in `open/`, rewritten
//! atomically at every heartbeat; one found at start-up belongs to a run that never ended (crash,
//! power cut). A damaged ledger is kept beside it (`ledger.corrupt-<unix seconds>`, the newest
//! `MAX_SET_ASIDE`).

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::usage::{DayRow, EndReason, Ledger, SessionRecord};
use ruya_flatpak::valid_session_app_id;
use ruya_ids::{flatpak_item, parse_item, valid_profile_id, ItemId};

pub type StoreResult<T> = Result<T, String>;

pub trait UsageStore {
    /// The profile's ledger; empty when it has none. Damaged data is moved aside, never
    /// overwritten silently.
    fn load(&mut self, profile: &str) -> StoreResult<Ledger>;
    fn append(&mut self, profile: &str, session: &SessionRecord) -> StoreResult<()>;
    fn rewrite(&mut self, profile: &str, ledger: &Ledger) -> StoreResult<()>;
    fn write_open(&mut self, profile: &str, key: &str, session: &SessionRecord) -> StoreResult<()>;
    fn remove_open(&mut self, profile: &str, key: &str);
    /// Running-session files left by a run that never ended: (profile, key, session).
    fn list_open(&mut self) -> Vec<(String, String, SessionRecord)>;
    fn remove_profile(&mut self, profile: &str);
    fn profiles(&mut self) -> Vec<String>;
}

// ---------------------------------------------------------------------------------------------
// The line format

fn clean_version(v: &str) -> String {
    let ok = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '+' | '~' | '-');
    if v.len() <= 32 && v.chars().all(ok) {
        v.to_owned()
    } else {
        String::new()
    }
}

pub fn encode_session(s: &SessionRecord) -> String {
    let days: Vec<String> = s.days.iter().map(|(d, n)| format!("{d}:{n}")).collect();
    format!(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
        line_head(SESSION, OLD_SESSION, &s.item, &s.app_id),
        s.app_id,
        clean_version(&s.app_version),
        s.start,
        s.end,
        s.foreground_seconds,
        s.reason.as_str(),
        days.join(",")
    )
}

pub fn encode_row(r: &DayRow) -> String {
    format!(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
        line_head(ROW, OLD_ROW, &r.item, &r.app_id),
        r.app_id,
        r.day,
        r.seconds,
        r.sessions,
        r.longest,
        r.first,
        r.last
    )
}

/// The tags of the ledger's lines; the line's form is its tag. `S` and `R` (T-247) carry no item:
/// theirs is the Flatpak app's (`flatpak:<app_id>`, all there was before ADR-041). `S2` and `R2`
/// (RUY-1051) carry the item after the tag, and are written only for an item that is not its app's
/// Flatpak item (a Steam game), so a ledger of Flatpak apps keeps the form an older image reads: a
/// rollback (greenboot, /var survives) keeps it until it has a Steam row, and then sets it aside
/// as damaged (kept, not deleted).
const SESSION: &str = "S2";
const ROW: &str = "R2";
const OLD_SESSION: &str = "S";
const OLD_ROW: &str = "R";

/// The tag (and the item, for the second form) a record's line starts with: the first form when
/// the item is the app's own Flatpak item, which the line's app id gives back.
fn line_head(tag: &str, old_tag: &str, item: &str, app_id: &str) -> String {
    if item == flatpak_item(app_id) {
        old_tag.to_owned()
    } else {
        format!("{tag}\t{item}")
    }
}

enum Line {
    Session(SessionRecord),
    Row(DayRow),
}

/// An item a line of the second form may carry for the app `app_id`: a Steam game, or the app's
/// own Flatpak item (never another app's).
fn valid_item(item: &str, app_id: &str) -> bool {
    match parse_item(item) {
        Some(ItemId::Flatpak(id)) => id == app_id,
        Some(ItemId::Steam(_)) => true,
        None => false,
    }
}

/// The item of a line: the one it carries, checked, or (`None`, a line of the first form) the
/// Flatpak app's own.
fn item_of(item: Option<&str>, app_id: &str) -> Option<String> {
    match item {
        Some(item) => valid_item(item, app_id).then(|| item.to_owned()),
        None => Some(flatpak_item(app_id)),
    }
}

fn decode(line: &str) -> Option<Line> {
    let f: Vec<&str> = line.split('\t').collect();
    let (tag, rest) = f.split_first()?;
    let (item, fields) = match *tag {
        SESSION | ROW => {
            let (item, fields) = rest.split_first()?;
            (Some(*item), fields)
        }
        OLD_SESSION | OLD_ROW => (None, rest),
        _ => return None,
    };
    let decoded = match *tag {
        SESSION | OLD_SESSION => Line::Session(decode_session(item, fields)?),
        _ => Line::Row(decode_row(item, fields)?),
    };
    Some(decoded)
}

fn decode_session(item: Option<&str>, f: &[&str]) -> Option<SessionRecord> {
    let [app, ver, start, end, fg, reason, days] = f else {
        return None;
    };
    if !valid_session_app_id(app) {
        return None;
    }
    let mut parsed = Vec::new();
    if !days.is_empty() {
        for part in days.split(',') {
            let (d, n) = part.split_once(':')?;
            parsed.push((d.parse().ok()?, n.parse().ok()?));
        }
    }
    Some(SessionRecord {
        item: item_of(item, app)?,
        app_id: (*app).to_owned(),
        app_version: clean_version(ver),
        start: start.parse().ok()?,
        end: end.parse().ok()?,
        foreground_seconds: fg.parse().ok()?,
        reason: EndReason::parse(reason)?,
        days: parsed,
        open: false,
    })
}

fn decode_row(item: Option<&str>, f: &[&str]) -> Option<DayRow> {
    let [app, day, secs, sessions, longest, first, last] = f else {
        return None;
    };
    if !valid_session_app_id(app) {
        return None;
    }
    Some(DayRow {
        item: item_of(item, app)?,
        app_id: (*app).to_owned(),
        day: day.parse().ok()?,
        seconds: secs.parse().ok()?,
        sessions: sessions.parse().ok()?,
        longest: longest.parse().ok()?,
        first: first.parse().ok()?,
        last: last.parse().ok()?,
    })
}

/// What a ledger file holds. A last line without its newline is a torn write (power cut during
/// an append): it is dropped and reported through the `bool`. Any other bad line is `Err`.
fn parse_ledger(text: &str) -> Result<(Ledger, bool), String> {
    let torn = !text.is_empty() && !text.ends_with('\n');
    let body = if torn {
        text.rfind('\n').map_or("", |i| &text[..=i])
    } else {
        text
    };
    let mut ledger = Ledger::default();
    for (n, line) in body.lines().enumerate() {
        match decode(line) {
            Some(Line::Session(s)) => ledger.sessions.push(s),
            Some(Line::Row(r)) => ledger.rows.push(r),
            None => return Err(format!("line {} is not a ledger record", n + 1)),
        }
    }
    Ok((ledger, torn))
}

/// How many damaged ledgers of a profile are kept beside it; the oldest beyond go.
pub const MAX_SET_ASIDE: usize = 3;

/// The name a damaged ledger gets (`ledger.corrupt-<unix>`, `-<n>` added when that is taken), or
/// the age of a kept one: (unix, n); the bare `ledger.corrupt` of the versions before RUY-1051 is
/// the oldest.
fn set_aside_age(name: &str) -> Option<(i64, u32)> {
    if name == "ledger.corrupt" {
        return Some((i64::MIN, 0));
    }
    let rest = name.strip_prefix("ledger.corrupt-")?;
    let (unix, n) = rest.split_once('-').unwrap_or((rest, "0"));
    Some((unix.parse().ok()?, n.parse().ok()?))
}

/// Moves the damaged ledger `path` aside as `ledger.corrupt-<unix>` (never over an earlier one)
/// and keeps the newest `MAX_SET_ASIDE` of them. Returns where it went.
fn set_aside(path: &Path, unix: i64) -> io::Result<PathBuf> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::other("a ledger has a folder"))?;
    let mut aside = dir.join(format!("ledger.corrupt-{unix}"));
    let mut n = 0;
    while aside.exists() {
        n += 1;
        aside = dir.join(format!("ledger.corrupt-{unix}-{n}"));
    }
    fs::rename(path, &aside)?;
    let mut kept: Vec<((i64, u32), PathBuf)> = fs::read_dir(dir)?
        .flatten()
        .filter_map(|e| {
            let age = set_aside_age(&e.file_name().to_string_lossy())?;
            Some((age, e.path()))
        })
        .collect();
    kept.sort();
    let excess = kept.len().saturating_sub(MAX_SET_ASIDE);
    for (_, old) in kept.into_iter().take(excess) {
        if let Err(e) = fs::remove_file(&old) {
            eprintln!("ruya-session: removing {} failed: {e}", old.display());
        }
    }
    Ok(aside)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

fn ledger_text(l: &Ledger) -> String {
    let mut out = String::new();
    for r in &l.rows {
        out.push_str(&encode_row(r));
    }
    for s in &l.sessions {
        out.push_str(&encode_session(s));
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Files

pub struct FileStore {
    root: PathBuf,
}

impl FileStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        FileStore { root: root.into() }
    }

    fn dir(&self, profile: &str) -> StoreResult<PathBuf> {
        if !valid_profile_id(profile) {
            return Err(format!("bad profile id {profile:?}"));
        }
        Ok(self.root.join(profile))
    }

    fn ledger_path(&self, profile: &str) -> StoreResult<PathBuf> {
        Ok(self.dir(profile)?.join("ledger.tsv"))
    }

    fn open_dir(&self, profile: &str) -> StoreResult<PathBuf> {
        Ok(self.dir(profile)?.join("open"))
    }
}

#[cfg(unix)]
fn restrict(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn restrict(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

fn private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    restrict(path, 0o700)
}

fn private_options() -> fs::OpenOptions {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut o = fs::OpenOptions::new();
        o.mode(0o600);
        o
    }
    #[cfg(not(unix))]
    {
        fs::OpenOptions::new()
    }
}

/// `ruya_fs::write_atomic` for text.
fn write_atomic(path: &Path, data: &str) -> io::Result<()> {
    ruya_fs::write_atomic(path, data.as_bytes())
}

fn err<T>(r: io::Result<T>) -> StoreResult<T> {
    r.map_err(|e| e.to_string())
}

/// A key names a file under `open/`: letters, digits and `._-` only.
fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 120
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

impl UsageStore for FileStore {
    fn load(&mut self, profile: &str) -> StoreResult<Ledger> {
        let path = self.ledger_path(profile)?;
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Ledger::default()),
            Err(e) => return Err(e.to_string()),
        };
        let parsed = String::from_utf8(bytes)
            .map_err(|e| e.to_string())
            .and_then(|t| parse_ledger(&t));
        match parsed {
            Ok((ledger, torn)) => {
                // A ledger of the first form (T-247) is read as it is and only appended to: it is
                // never rewritten for being old (RUY-1051).
                if torn {
                    eprintln!(
                        "ruya-session: dropped a torn last line of {}",
                        path.display()
                    );
                    err(write_atomic(&path, &ledger_text(&ledger)))?;
                }
                Ok(ledger)
            }
            Err(why) => {
                // Not ours to delete: keep the damaged file, start a new ledger.
                let aside = err(set_aside(&path, unix_now()))?;
                eprintln!(
                    "ruya-session: {} is damaged ({why}); kept as {}",
                    path.display(),
                    aside.display()
                );
                Ok(Ledger::default())
            }
        }
    }

    fn append(&mut self, profile: &str, session: &SessionRecord) -> StoreResult<()> {
        let dir = self.dir(profile)?;
        err(private_dir(&dir))?;
        let path = self.ledger_path(profile)?;
        let line = encode_session(session);
        let mut f = err(private_options().append(true).create(true).open(&path))?;
        // One write of the whole line: the file holds all of it or none (or a torn tail that
        // `load` drops).
        err(f.write_all(line.as_bytes()))?;
        err(f.sync_data())
    }

    fn rewrite(&mut self, profile: &str, ledger: &Ledger) -> StoreResult<()> {
        let dir = self.dir(profile)?;
        err(private_dir(&dir))?;
        err(write_atomic(
            &self.ledger_path(profile)?,
            &ledger_text(ledger),
        ))
    }

    fn write_open(&mut self, profile: &str, key: &str, session: &SessionRecord) -> StoreResult<()> {
        if !valid_key(key) {
            return Err(format!("bad key {key:?}"));
        }
        let dir = self.open_dir(profile)?;
        err(private_dir(&self.dir(profile)?))?;
        err(private_dir(&dir))?;
        err(write_atomic(
            &dir.join(format!("{key}.rec")),
            &encode_session(session),
        ))
    }

    fn remove_open(&mut self, profile: &str, key: &str) {
        if !valid_key(key) {
            return;
        }
        if let Ok(dir) = self.open_dir(profile) {
            let _ = fs::remove_file(dir.join(format!("{key}.rec")));
        }
    }

    fn list_open(&mut self) -> Vec<(String, String, SessionRecord)> {
        let mut out = Vec::new();
        for profile in self.profiles() {
            let Ok(dir) = self.open_dir(&profile) else {
                continue;
            };
            let Ok(entries) = fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                let Some(key) = name.strip_suffix(".rec") else {
                    continue;
                };
                let Ok(text) = fs::read_to_string(entry.path()) else {
                    continue;
                };
                if let Some(Line::Session(s)) = text.lines().next().and_then(decode) {
                    out.push((profile.clone(), key.to_owned(), s));
                }
            }
        }
        out
    }

    fn remove_profile(&mut self, profile: &str) {
        if let Ok(dir) = self.dir(profile) {
            if let Err(e) = fs::remove_dir_all(&dir) {
                if e.kind() != io::ErrorKind::NotFound {
                    eprintln!("ruya-session: removing {} failed: {e}", dir.display());
                }
            }
        }
    }

    fn profiles(&mut self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return Vec::new();
        };
        let mut ids: Vec<String> = entries
            .flatten()
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| valid_profile_id(n))
            .collect();
        ids.sort();
        ids
    }
}

// ---------------------------------------------------------------------------------------------
// In memory (tests)

#[derive(Default)]
pub struct MemStore {
    pub ledgers: BTreeMap<String, Ledger>,
    pub opens: BTreeMap<(String, String), SessionRecord>,
    /// Every write counted, so a test can see when nothing was written.
    pub writes: usize,
}

impl UsageStore for MemStore {
    fn load(&mut self, profile: &str) -> StoreResult<Ledger> {
        Ok(self.ledgers.get(profile).cloned().unwrap_or_default())
    }

    fn append(&mut self, profile: &str, session: &SessionRecord) -> StoreResult<()> {
        self.writes += 1;
        self.ledgers
            .entry(profile.to_owned())
            .or_default()
            .sessions
            .push(session.clone());
        Ok(())
    }

    fn rewrite(&mut self, profile: &str, ledger: &Ledger) -> StoreResult<()> {
        self.writes += 1;
        self.ledgers.insert(profile.to_owned(), ledger.clone());
        Ok(())
    }

    fn write_open(&mut self, profile: &str, key: &str, session: &SessionRecord) -> StoreResult<()> {
        self.writes += 1;
        self.opens
            .insert((profile.to_owned(), key.to_owned()), session.clone());
        Ok(())
    }

    fn remove_open(&mut self, profile: &str, key: &str) {
        self.opens.remove(&(profile.to_owned(), key.to_owned()));
    }

    fn list_open(&mut self) -> Vec<(String, String, SessionRecord)> {
        self.opens
            .iter()
            .map(|((p, k), s)| (p.clone(), k.clone(), s.clone()))
            .collect()
    }

    fn remove_profile(&mut self, profile: &str) {
        self.ledgers.remove(profile);
        self.opens.retain(|(p, _), _| p != profile);
    }

    fn profiles(&mut self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .ledgers
            .keys()
            .cloned()
            .chain(self.opens.keys().map(|(p, _)| p.clone()))
            .collect();
        ids.sort();
        ids.dedup();
        ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::testing::rec;

    const A: &str = "org.ruyaos.Racer";

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ruya-usage-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn lines_round_trip() {
        let mut s = rec(A, 1_000, 500, 20_400);
        s.days = vec![(20_400, 300), (20_401, 200)];
        s.reason = EndReason::TimeLimit;
        // A Flatpak app's record keeps the form an older image reads (RUY-1051).
        let text = encode_session(&s);
        assert_eq!(
            text,
            "S\torg.ruyaos.Racer\t1.0\t1000\t1500\t500\ttime-limit\t20400:300,20401:200\n"
        );
        let (l, torn) = parsed(&text);
        assert!(!torn);
        assert_eq!(l.sessions, [s.clone()]);
        // Any other item is written with it, in the second form.
        s.item = "steam:70".to_owned();
        let text = encode_session(&s);
        assert_eq!(
            text,
            "S2\tsteam:70\torg.ruyaos.Racer\t1.0\t1000\t1500\t500\ttime-limit\t20400:300,20401:200\n"
        );
        assert_eq!(parsed(&text).0.sessions, [s]);
        let mut r = DayRow {
            app_id: A.to_owned(),
            item: flatpak_item(A),
            day: 5,
            seconds: 6,
            sessions: 1,
            longest: 6,
            first: 7,
            last: 8,
        };
        assert_eq!(encode_row(&r), "R\torg.ruyaos.Racer\t5\t6\t1\t6\t7\t8\n");
        assert_eq!(parsed(&encode_row(&r)).0.rows, [r.clone()]);
        r.item = "steam:70".to_owned();
        assert_eq!(
            encode_row(&r),
            "R2\tsteam:70\torg.ruyaos.Racer\t5\t6\t1\t6\t7\t8\n"
        );
        assert_eq!(parsed(&encode_row(&r)).0.rows, [r]);
    }

    /// `parse_ledger` of a text that must parse.
    fn parsed(text: &str) -> (Ledger, bool) {
        parse_ledger(text).unwrap_or_else(|e| panic!("{e}: {text:?}"))
    }

    /// A ledger of the first form (T-247 up to RUY-1051): no item ids.
    const OLD_LEDGER: &str = "R\torg.ruyaos.Racer\t20300\t1000\t2\t700\t5\t6\n\
                              S\torg.ruyaos.Racer\t1.0\t1000\t1500\t500\tquit\t20400:500\n";

    #[test]
    fn lines_of_the_first_form_are_read_as_flatpak_items() {
        let (l, torn) = parsed(OLD_LEDGER);
        assert!(!torn);
        assert_eq!(l.rows[0].item, "flatpak:org.ruyaos.Racer");
        assert_eq!(l.sessions[0].item, "flatpak:org.ruyaos.Racer");
        assert_eq!(
            (l.sessions[0].start, l.sessions[0].days.as_slice()),
            (1000, [(20_400, 500)].as_slice())
        );
        // Both forms in one file: a Steam game's session appended to an old ledger.
        let mut game = rec(A, 2_000, 60, 5);
        game.item = "steam:70".to_owned();
        let (l, _) = parsed(&format!("{OLD_LEDGER}{}", encode_session(&game)));
        assert_eq!(l.sessions.len(), 2);
        assert_eq!(l.sessions[1].item, "steam:70");
        // A Flatpak-only ledger is written back in the first form, line for line.
        assert_eq!(ledger_text(&parsed(OLD_LEDGER).0), OLD_LEDGER);
    }

    #[test]
    fn an_old_ledger_is_never_rewritten_only_appended_to() {
        let root = tmp("old-form");
        let dir = root.join("p1");
        fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("{e}"));
        let path = dir.join("ledger.tsv");
        fs::write(&path, OLD_LEDGER).unwrap_or_else(|e| panic!("{e}"));
        let mut st = FileStore::new(&root);
        let l = st.load("p1").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!((l.rows.len(), l.sessions.len()), (1, 1));
        assert_eq!(
            fs::read_to_string(&path).unwrap_or_default(),
            OLD_LEDGER,
            "the load leaves the file as it was"
        );
        assert_eq!(st.append("p1", &rec(A, 2_000, 60, 5)), Ok(()));
        let text = fs::read_to_string(&path).unwrap_or_default();
        assert_eq!(
            text,
            format!("{OLD_LEDGER}S\torg.ruyaos.Racer\t1.0\t2000\t2060\t60\tquit\t5:60\n"),
            "appended in the first form"
        );
        let names: Vec<String> = fs::read_dir(&dir)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        assert_eq!(names, ["ledger.tsv"], "nothing set aside");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_old_heartbeat_file_is_still_read() {
        let root = tmp("old-open");
        let open = root.join("p1").join("open");
        fs::create_dir_all(&open).unwrap_or_else(|e| panic!("{e}"));
        fs::write(
            open.join("100-unit.rec"),
            "S\torg.ruyaos.Racer\t1.0\t100\t160\t60\tquit\t5:60\n",
        )
        .unwrap_or_else(|e| panic!("{e}"));
        let left = FileStore::new(&root).list_open();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].2.item, "flatpak:org.ruyaos.Racer");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_hostile_version_is_not_written() {
        let mut s = rec(A, 0, 20, 0);
        s.app_version = "1\t2\nS\tevil".to_owned();
        assert!(encode_session(&s).contains("\t\t0\t")); // empty version
        assert_eq!(encode_session(&s).matches('\n').count(), 1);
    }

    #[test]
    fn bad_lines_are_errors_and_a_torn_tail_is_not() {
        assert!(parse_ledger("S\tnot an app\t\t1\t2\t3\tquit\t\n").is_err());
        assert!(parse_ledger("X\t1\n").is_err());
        assert!(parse_ledger("S\torg.a.b\t\t1\t2\t3\tnope\t0:3\n").is_err());
        // The second form: its own Flatpak item or a Steam game, nothing else.
        let line =
            |item: &str| format!("S2\t{item}\torg.ruyaos.Racer\t1.0\t1\t31\t30\tquit\t0:30\n");
        assert_eq!(
            parsed(&line("flatpak:org.ruyaos.Racer")).0.sessions[0].item,
            "flatpak:org.ruyaos.Racer"
        );
        for item in [
            "",
            "steam:x",
            "play:a",
            "flatpak:org.other.App",
            "flatpak:not an app",
            "flatpak:",
        ] {
            assert!(parse_ledger(&line(item)).is_err(), "{item:?}");
        }
        assert!(
            parse_ledger("R2\tflatpak:org.other.App\torg.ruyaos.Racer\t5\t6\t1\t6\t7\t8\n")
                .is_err()
        );
        assert!(parse_ledger("S2\torg.ruyaos.Racer\t1.0\t1000\t1500\t500\tquit\t0:3\n").is_err());
        assert!(parse_ledger("S\tsteam:70\torg.a.b\t\t1\t2\t3\tquit\t0:3\n").is_err());
        let ok = encode_session(&rec(A, 1, 30, 0));
        let (l, torn) = parsed(&format!("{ok}S2\tsteam:7"));
        assert!(torn);
        assert_eq!(l.sessions.len(), 1);
    }

    #[test]
    fn files_append_reload_and_rewrite() {
        let root = tmp("files");
        let mut st = FileStore::new(&root);
        assert!(st.load("p1").is_ok_and(|l| l.sessions.is_empty()));
        assert_eq!(st.append("p1", &rec(A, 1_000, 60, 5)), Ok(()));
        assert_eq!(st.append("p1", &rec(A, 2_000, 90, 5)), Ok(()));
        let l = st.load("p1").unwrap_or_default();
        assert_eq!(l.sessions.len(), 2);
        let mut l2 = l.clone();
        l2.roll_up(5, 1_000_000_000);
        assert_eq!(st.rewrite("p1", &l2), Ok(()));
        let again = st.load("p1").unwrap_or_default();
        assert_eq!((again.sessions.len(), again.rows.len()), (0, 1));
        assert_eq!(st.profiles(), ["p1"]);
        st.remove_profile("p1");
        assert!(st.profiles().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn other_profiles_files_are_not_read() {
        let root = tmp("cross");
        let mut st = FileStore::new(&root);
        assert_eq!(st.append("p1", &rec(A, 1_000, 60, 5)), Ok(()));
        assert!(st.load("p2").is_ok_and(|l| l.sessions.is_empty()));
        for bad in ["", "..", "../p1", "p1/..", "a b"] {
            assert!(st.load(bad).is_err(), "{bad:?}");
            assert!(st.append(bad, &rec(A, 1, 60, 5)).is_err(), "{bad:?}");
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_torn_tail_is_repaired_and_a_damaged_file_is_kept() {
        let root = tmp("torn");
        let mut st = FileStore::new(&root);
        assert_eq!(st.append("p1", &rec(A, 1_000, 60, 5)), Ok(()));
        let path = root.join("p1").join("ledger.tsv");
        let mut f = fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("{e}"));
        f.write_all(b"S\torg.ruyaos.Ra")
            .unwrap_or_else(|e| panic!("{e}"));
        drop(f);
        let l = st.load("p1").unwrap_or_default();
        assert_eq!(l.sessions.len(), 1);
        // The tail is gone from the file: the next append does not glue onto it.
        assert_eq!(st.append("p1", &rec(A, 2_000, 60, 5)), Ok(()));
        assert_eq!(st.load("p1").unwrap_or_default().sessions.len(), 2);

        fs::write(&path, "garbage\n").unwrap_or_else(|e| panic!("{e}"));
        let l = st.load("p1").unwrap_or_default();
        assert!(l.sessions.is_empty());
        let kept = set_asides(&root.join("p1"));
        assert_eq!(kept.len(), 1, "{kept:?}");
        assert_eq!(
            fs::read_to_string(root.join("p1").join(&kept[0])).unwrap_or_default(),
            "garbage\n",
            "the damaged data is kept, not overwritten"
        );
        let _ = fs::remove_dir_all(&root);
    }

    /// The names of the damaged ledgers kept in `dir`, oldest first.
    fn set_asides(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| set_aside_age(n).is_some())
                    .collect()
            })
            .unwrap_or_default();
        names.sort_by_key(|n| set_aside_age(n));
        names
    }

    #[test]
    fn every_set_aside_is_kept_up_to_the_cap() {
        let root = tmp("asides");
        let dir = root.join("p1");
        fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("{e}"));
        let path = dir.join("ledger.tsv");
        // One left by a version before RUY-1051, then two in the same second, then later ones.
        fs::write(dir.join("ledger.corrupt"), "first\n").unwrap_or_else(|e| panic!("{e}"));
        for (n, unix) in [(1, 100), (2, 100)] {
            fs::write(&path, format!("bad {n}\n")).unwrap_or_else(|e| panic!("{e}"));
            assert!(set_aside(&path, unix).is_ok());
        }
        assert_eq!(
            set_asides(&dir),
            [
                "ledger.corrupt",
                "ledger.corrupt-100",
                "ledger.corrupt-100-1"
            ],
            "a second set-aside does not overwrite the first"
        );
        let read = |name: &str| fs::read_to_string(dir.join(name)).unwrap_or_default();
        assert_eq!(
            (read("ledger.corrupt-100"), read("ledger.corrupt-100-1")),
            ("bad 1\n".to_owned(), "bad 2\n".to_owned())
        );
        for (n, unix) in [(3, 200), (4, 300)] {
            fs::write(&path, format!("bad {n}\n")).unwrap_or_else(|e| panic!("{e}"));
            assert!(set_aside(&path, unix).is_ok());
        }
        assert_eq!(
            set_asides(&dir),
            [
                "ledger.corrupt-100-1",
                "ledger.corrupt-200",
                "ledger.corrupt-300"
            ],
            "the newest MAX_SET_ASIDE are kept"
        );
        assert!(!path.exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn open_files_are_written_listed_and_removed() {
        let root = tmp("open");
        let mut st = FileStore::new(&root);
        let mut s = rec(A, 1_000, 60, 5);
        s.open = true;
        assert_eq!(st.write_open("p1", "100-unit", &s), Ok(()));
        assert!(st.write_open("p1", "../x", &s).is_err());
        assert!(st.write_open("p1", "", &s).is_err());
        // A leftover temporary file is not a record.
        let _ = fs::write(root.join("p1").join("open").join("x.tmp"), "S");
        let left = st.list_open();
        assert_eq!(left.len(), 1);
        assert_eq!((left[0].0.as_str(), left[0].1.as_str()), ("p1", "100-unit"));
        assert_eq!(left[0].2.foreground_seconds, 60);
        st.remove_open("p1", "100-unit");
        assert!(st.list_open().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn files_and_directories_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let root = tmp("modes");
        let mut st = FileStore::new(&root);
        let mut s = rec(A, 1_000, 60, 5);
        assert_eq!(st.append("p1", &s), Ok(()));
        assert_eq!(st.rewrite("p1", &Ledger::default()), Ok(()));
        s.open = true;
        assert_eq!(st.write_open("p1", "k", &s), Ok(()));
        let mode = |p: PathBuf| {
            fs::metadata(p)
                .map(|m| m.permissions().mode() & 0o777)
                .unwrap_or(0)
        };
        assert_eq!(mode(root.join("p1")), 0o700);
        assert_eq!(mode(root.join("p1").join("open")), 0o700);
        assert_eq!(mode(root.join("p1").join("ledger.tsv")), 0o600);
        assert_eq!(mode(root.join("p1").join("open").join("k.rec")), 0o600);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_rewrite_leaves_no_temporary_file() {
        let root = tmp("atomic");
        let mut st = FileStore::new(&root);
        assert_eq!(st.rewrite("p1", &Ledger::default()), Ok(()));
        let names: Vec<String> = fs::read_dir(root.join("p1"))
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        assert_eq!(names, ["ledger.tsv"]);
        let _ = fs::remove_dir_all(&root);
    }
}
