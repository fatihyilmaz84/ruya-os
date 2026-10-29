//! Installed Flatpak apps, from the text output of
//! `flatpak list --app --columns=application,name,origin` (tab-separated, no header).

use crate::catalog::{Item, Kind, Source};

/// Runs `flatpak list`; a trait so the rest is testable without Flatpak.
pub trait AppLister: Send + Sync {
    /// The raw output of the list command.
    fn list(&self) -> Result<String, String>;
}

/// Fixed output, for tests and `--session` development.
pub struct FixtureLister(pub String);

impl AppLister for FixtureLister {
    fn list(&self) -> Result<String, String> {
        Ok(self.0.clone())
    }
}

#[cfg(target_os = "linux")]
pub struct FlatpakCli;

#[cfg(target_os = "linux")]
impl AppLister for FlatpakCli {
    fn list(&self) -> Result<String, String> {
        let out = std::process::Command::new("flatpak")
            .args(["list", "--app", "--columns=application,name,origin"])
            .output()
            .map_err(|e| format!("cannot run flatpak: {e}"))?;
        if !out.status.success() {
            return Err(format!("flatpak list failed: {}", out.status));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

/// One item per row. A row without an application id is skipped; a missing name falls back to
/// the id. The origin column is not used yet.
pub fn parse_list(output: &str) -> Vec<Item> {
    output
        .lines()
        .filter_map(|line| {
            let mut cols = line.split('\t').map(str::trim);
            let id = cols.next().filter(|id| !id.is_empty())?;
            let title = cols.next().filter(|t| !t.is_empty()).unwrap_or(id);
            Some(Item {
                id: format!("flatpak:{id}"),
                kind: Kind::App,
                title: title.to_owned(),
                source: Source::Flatpak,
                launch: format!("flatpak:{id}"),
                art: Vec::new(),
                last_played: 0,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_output_is_no_items() {
        assert!(parse_list("").is_empty());
        assert!(parse_list("\n\n").is_empty());
    }

    #[test]
    fn normal_rows() {
        let items =
            parse_list("org.example.Racer\tTurbo Racer\tflathub\norg.example.Doc\tDocs\tflathub\n");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "flatpak:org.example.Racer");
        assert_eq!(items[0].title, "Turbo Racer");
        assert_eq!(items[0].launch, "flatpak:org.example.Racer");
        assert_eq!(items[0].kind, Kind::App);
        assert_eq!(items[0].source, Source::Flatpak);
    }

    #[test]
    fn rows_with_missing_columns() {
        let items =
            parse_list("org.example.OnlyId\norg.example.NoOrigin\tNamed\n\torphan name\t\n");
        assert_eq!(items.len(), 2, "the row without an id is skipped");
        assert_eq!(items[0].title, "org.example.OnlyId");
        assert_eq!(items[1].title, "Named");
    }

    #[test]
    fn windows_line_endings_and_blank_rows() {
        let items = parse_list("a.b.C\tCee\tflathub\r\n\r\n");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Cee");
    }
}
