//! The store's view of an app (the `a{sv}` record of the contract) and the statuses.

pub use crate::appstream::Screenshot;

/// Status strings of the method replies (stable API, `api/dbus/org.ruyaos.Store1.xml`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownApp,
    AlreadyInstalled,
    NotInstalled,
    NoUpdate,
    /// Install or Update of an app whose minimum API level is above this console's.
    Incompatible,
    Busy,
    Forbidden,
    Invalid,
    /// A permission the console does not withdraw (WithdrawPermission, RestorePermission).
    NotWithdrawable,
    /// Install, Update, Uninstall or Rollback of an installed `.play` app: `Play1` owns those (RUY-1244).
    PlayManaged,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownApp => "unknown-app",
            Status::AlreadyInstalled => "already-installed",
            Status::NotInstalled => "not-installed",
            Status::NoUpdate => "no-update",
            Status::Incompatible => "incompatible",
            Status::Busy => "busy",
            Status::Forbidden => "forbidden",
            Status::Invalid => "invalid",
            Status::NotWithdrawable => "not-withdrawable",
            Status::PlayManaged => "play-managed",
            Status::Failed => "failed",
        }
    }
}

/// Statuses of the `JobFinished` signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobStatus {
    Ok,
    Failed,
    Network,
    Signature,
    MissingRuntime,
    DiskFull,
}

impl JobStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            JobStatus::Ok => "ok",
            JobStatus::Failed => "failed",
            JobStatus::Network => "network",
            JobStatus::Signature => "signature",
            JobStatus::MissingRuntime => "missing-runtime",
            JobStatus::DiskFull => "disk-full",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "ok" => JobStatus::Ok,
            "failed" => JobStatus::Failed,
            "network" => JobStatus::Network,
            "signature" => JobStatus::Signature,
            "missing-runtime" => JobStatus::MissingRuntime,
            "disk-full" => JobStatus::DiskFull,
            _ => return None,
        })
    }
}

/// One app of the catalogue. Empty strings mean "not known" (the contract allows "" for the art).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct App {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub description: String,
    pub developer: String,
    /// "official" | "community" | "developer": the trust level of the remote it comes from.
    pub source: String,
    /// "full" | "partial" | "none"
    pub controller: String,
    /// "all" | "7+" | "12+" | "16+" | "18+", "" when the metadata has no rating.
    pub age_rating: String,
    /// The API level the app asks for (`x-ruya-min-api-level`), 0 when it names none.
    pub min_api_level: u32,
    /// `min_api_level` is not above this console's level. True for an app AppStream does not
    /// describe; the shell hides an incompatible app from the Store lists.
    pub compatible: bool,
    pub permissions: Vec<String>,
    /// What the available update adds to the installed version's permissions; only `get_app`
    /// fills it, empty without an update.
    pub new_permissions: Vec<String>,
    pub installed_size: u64,
    /// Bytes an install downloads, 0 unknown.
    pub download_size: u64,
    /// Newest release in the remote's AppStream, "" unknown.
    pub version: String,
    /// Unix seconds of that release, 0 unknown.
    pub release_date: i64,
    /// Plain text of that release's notes; `get_app` only.
    pub release_notes: String,
    /// Version flatpak reports for the installed app, "" unknown.
    pub installed_version: String,
    pub license: String,
    pub categories: Vec<String>,
    /// `get_app` only.
    pub screenshots: Vec<Screenshot>,
    pub icon: String,
    pub tile: String,
    pub hero: String,
    pub installed: bool,
    pub update_available: bool,
    /// Where to install it from (not part of the record).
    pub remote: String,
    /// The remote Flatpak says the installed app came from (`flatpak list`'s origin column), "" when
    /// it is not installed or the column was empty. Not part of the record; `is_play_managed` reads it.
    pub origin: String,
}

impl App {
    /// An installed app of the console's own `.play` remote: `Play1` installs, updates, rolls back
    /// and removes it, so the Store's mutations refuse it (RUY-1244). An unread origin is not `.play`:
    /// `play.*` is also a name Flathub may ship.
    pub fn is_play_managed(&self) -> bool {
        self.installed && self.origin == ruya_play_art::PLAY_REMOTE
    }

    /// Name, summary or id contains the query, ignoring case. "" matches everything.
    pub fn matches(&self, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        if query.is_empty() {
            return true;
        }
        [&self.name, &self.summary, &self.id]
            .iter()
            .any(|field| field.to_lowercase().contains(&query))
    }
}

/// A remote name as flatpak accepts it, and nothing that could be read as an option.
pub fn valid_remote_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.starts_with(|c: char| c.is_ascii_alphanumeric())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

/// A commit id as `flatpak update --commit` takes it.
pub fn valid_commit(commit: &str) -> bool {
    (6..=64).contains(&commit.len()) && commit.chars().all(|c| c.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app() -> App {
        App {
            id: "org.example.Racer".into(),
            name: "Turbo Racer".into(),
            summary: "Drive fast".into(),
            ..App::default()
        }
    }

    #[test]
    fn search_matches_name_summary_and_id_ignoring_case() {
        let a = app();
        assert!(a.matches("turbo"));
        assert!(a.matches("DRIVE"));
        assert!(a.matches("example.racer"));
        assert!(a.matches(""));
        assert!(a.matches("  "));
        assert!(!a.matches("puzzle"));
    }

    #[test]
    fn remote_names_and_commits() {
        assert!(valid_remote_name("ruyaos-beta"));
        assert!(!valid_remote_name("-oops"));
        assert!(!valid_remote_name("a b"));
        assert!(!valid_remote_name(""));
        assert!(valid_commit("0a1b2c3d4e5f"));
        assert!(!valid_commit("abc"));
        assert!(!valid_commit("--user"));
        assert!(!valid_commit("zzzzzzzz"));
    }
}
