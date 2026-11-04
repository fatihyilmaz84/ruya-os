//! Change detection for the system Flatpak installation (T-163).
//!
//! The Store (or `flatpak` on the command line) installs and removes apps; the library must notice
//! without a reboot. The pure part is `fingerprint`: the names of the deployed apps and of the
//! exported desktop entries. When the fingerprint differs from the last one, the caller scans
//! again (and `Rescan` only emits `ItemsChanged` if the list really differs). The polling loop in
//! `main.rs` is the glue and is not unit-tested.
//!
//! Why polling and not inotify: no new dependency (the `inotify` crate is Linux-only and cannot be
//! tested on the Windows host), the cost is two `readdir` calls every few seconds, and a change
//! shows up within one interval. Names only, no mtimes: flatpak touches directories while it works.

use std::path::Path;

/// A sorted list of `app/<name>` and `desktop/<name>` entries; equal when nothing was installed
/// or removed.
pub type Fingerprint = Vec<String>;

fn names(dir: &Path, prefix: &str, out: &mut Fingerprint) {
    // A missing directory (no app installed yet, no Flatpak) is an empty one.
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            out.push(format!("{prefix}/{}", entry.file_name().to_string_lossy()));
        }
    }
}

/// What the installation at `root` (normally `/var/lib/flatpak`) holds right now.
pub fn fingerprint(root: &Path) -> Fingerprint {
    let mut out = Vec::new();
    names(&root.join("app"), "app", &mut out);
    names(
        &root.join("exports/share/applications"),
        "desktop",
        &mut out,
    );
    out.sort();
    out
}

/// Remembers the last fingerprint. The first call only records it: the service has just scanned.
#[derive(Default)]
pub struct Watcher {
    last: Option<Fingerprint>,
}

impl Watcher {
    pub fn new() -> Self {
        Watcher::default()
    }

    /// True when `current` differs from the previous call's.
    pub fn changed(&mut self, current: Fingerprint) -> bool {
        let changed = self.last.as_ref().is_some_and(|last| *last != current);
        self.last = Some(current);
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install(root: &Path, id: &str) {
        std::fs::create_dir_all(root.join("app").join(id)).unwrap();
        let apps = root.join("exports/share/applications");
        std::fs::create_dir_all(&apps).unwrap();
        std::fs::write(apps.join(format!("{id}.desktop")), "[Desktop Entry]\n").unwrap();
    }

    fn uninstall(root: &Path, id: &str) {
        std::fs::remove_dir_all(root.join("app").join(id)).unwrap();
        std::fs::remove_file(
            root.join("exports/share/applications")
                .join(format!("{id}.desktop")),
        )
        .unwrap();
    }

    #[test]
    fn a_missing_installation_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(fingerprint(&dir.path().join("nothing-here")).is_empty());
    }

    #[test]
    fn install_and_uninstall_change_the_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let empty = fingerprint(root);
        install(root, "org.example.Racer");
        let one = fingerprint(root);
        assert_ne!(empty, one);
        assert_eq!(
            one,
            ["app/org.example.Racer", "desktop/org.example.Racer.desktop"]
        );
        install(root, "org.example.Notes");
        assert_ne!(one, fingerprint(root));
        uninstall(root, "org.example.Racer");
        uninstall(root, "org.example.Notes");
        assert_eq!(empty, fingerprint(root));
    }

    #[test]
    fn the_same_state_gives_the_same_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        install(dir.path(), "a.b.C");
        install(dir.path(), "d.e.F");
        assert_eq!(fingerprint(dir.path()), fingerprint(dir.path()));
    }

    #[test]
    fn the_watcher_reports_only_real_changes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut w = Watcher::new();
        assert!(
            !w.changed(fingerprint(root)),
            "the first look is a baseline"
        );
        assert!(!w.changed(fingerprint(root)), "nothing happened");
        install(root, "a.b.C");
        assert!(w.changed(fingerprint(root)), "install");
        assert!(!w.changed(fingerprint(root)), "reported once");
        uninstall(root, "a.b.C");
        assert!(w.changed(fingerprint(root)), "uninstall");
    }
}
