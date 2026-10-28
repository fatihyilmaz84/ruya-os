//! The store's view of an app (the `a{sv}` record of the contract) and the statuses.

/// Status strings of the method replies (stable API, `api/dbus/org.ruyaos.Store1.xml`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownApp,
    AlreadyInstalled,
    NotInstalled,
    NoUpdate,
    Busy,
    Forbidden,
    Invalid,
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
            Status::Busy => "busy",
            Status::Forbidden => "forbidden",
            Status::Invalid => "invalid",
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
    pub permissions: Vec<String>,
    pub installed_size: u64,
    pub icon: String,
    pub tile: String,
    pub hero: String,
    pub installed: bool,
    pub update_available: bool,
    /// Where to install it from (not part of the record).
    pub remote: String,
}

impl App {
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

/// A Flatpak application id: reverse-DNS, ASCII letters, digits, `_` and `-`, at least two dots.
/// Everything that reaches the `flatpak` command line has passed this.
pub fn valid_app_id(id: &str) -> bool {
    id.len() <= 255
        && !id.starts_with('-')
        && id.split('.').count() >= 3
        && id.split('.').all(|part| {
            !part.is_empty()
                && !part.starts_with(|c: char| c.is_ascii_digit())
                && part
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        })
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
    fn app_ids() {
        assert!(valid_app_id("org.example.Racer"));
        assert!(valid_app_id("org.ruyaos.Test_App-2"));
        for bad in [
            "",
            "Racer",
            "org.example",
            "-org.example.Racer",
            "org..Racer",
            "org.1example.Racer",
            "org.example.Racer --user",
            "org.example.Rac/er",
            "org.example.Racer\n",
        ] {
            assert!(!valid_app_id(bad), "{bad:?}");
        }
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
