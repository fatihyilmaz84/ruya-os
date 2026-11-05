//! Change detection for the system Flatpak installation (T-163).
//!
//! The Store (or `flatpak` on the command line) installs, updates and removes apps; the library
//! must notice without a reboot. The pure part is `fingerprint`: the names of the deployed apps
//! and of the exported desktop entries, and for every deployed app the commit of each of its
//! branches (T-183), so an update that renames or recategorises an app is seen too. When the fingerprint differs from the last one, the caller scans
//! again (and `Rescan` only emits `ItemsChanged` if the list really differs). The polling loop in
//! `main.rs` is the glue and is not unit-tested.
//!
//! Why polling and not inotify: no new dependency (the `inotify` crate is Linux-only and cannot be
//! tested on the Windows host), the cost is a few `readdir` calls per app every few seconds, and a
//! change shows up within one interval. Names only, no mtimes: flatpak touches directories while
//! it works.
//!
//! The deploy commit: Flatpak lays an app out as `app/<id>/<arch>/<branch>/<commit>/` (with a
//! `deploy` file once the deployment is complete) and points the symlink `active` at the commit
//! in use. An update deploys a new commit directory and then moves `active`; both are in the
//! fingerprint, so a half-finished deployment (a commit directory without `deploy`) is not
//! reported before it is usable, and a rollback (only `active` moves) is.

use std::path::Path;

/// A sorted list of `app/<name>`, `desktop/<name>`, `active/<id>/<arch>/<branch>=<commit>` and
/// `commit/<id>/<arch>/<branch>/<commit>` entries; equal when nothing was installed, updated or
/// removed.
pub type Fingerprint = Vec<String>;

fn names(dir: &Path, prefix: &str, out: &mut Fingerprint) {
    // A missing directory (no app installed yet, no Flatpak) is an empty one.
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            out.push(format!("{prefix}/{}", entry.file_name().to_string_lossy()));
        }
    }
}

fn subdirs(dir: &Path) -> Vec<String> {
    // `file_type` does not follow symlinks: `current` and `active` are not directories here.
    // Hidden names are skipped: flatpak checks a deployment out into `.<checksum>-XXXXXX` and
    // renames it when it is complete.
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if entry.file_type().is_ok_and(|t| t.is_dir()) && !name.starts_with('.') {
                out.push(name);
            }
        }
    }
    out
}

/// The commits of every branch of the app `id` under `apps` (`app/<id>/<arch>/<branch>`).
fn deployments(apps: &Path, id: &str, out: &mut Fingerprint) {
    for arch in subdirs(&apps.join(id)) {
        for branch in subdirs(&apps.join(id).join(&arch)) {
            let dir = apps.join(id).join(&arch).join(&branch);
            if let Ok(target) = std::fs::read_link(dir.join("active")) {
                out.push(format!(
                    "active/{id}/{arch}/{branch}={}",
                    target.to_string_lossy()
                ));
            }
            for commit in subdirs(&dir) {
                if dir.join(&commit).join("deploy").is_file() {
                    out.push(format!("commit/{id}/{arch}/{branch}/{commit}"));
                }
            }
        }
    }
}

/// What the installation at `root` (normally `/var/lib/flatpak`) holds right now.
pub fn fingerprint(root: &Path) -> Fingerprint {
    let mut out = Vec::new();
    names(&root.join("app"), "app", &mut out);
    for id in subdirs(&root.join("app")) {
        deployments(&root.join("app"), &id, &mut out);
    }
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

    /// Deploys `commit` of `id` (stable branch, x86_64) the way flatpak does: a directory with a
    /// `deploy` file. `active` is a symlink and tested separately (Windows may not allow it).
    fn deploy(root: &Path, id: &str, commit: &str) {
        let dir = root.join("app").join(id).join("x86_64/stable").join(commit);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("deploy"), "x").unwrap();
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
    fn an_update_that_only_changes_the_deploy_commit_changes_the_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        install(root, "org.example.Racer");
        deploy(root, "org.example.Racer", "aaaa");
        let before = fingerprint(root);
        // Same app name, same exported desktop entry: only the commit differs.
        deploy(root, "org.example.Racer", "bbbb");
        let after = fingerprint(root);
        assert_ne!(before, after);
        assert!(after.contains(&"commit/org.example.Racer/x86_64/stable/bbbb".to_owned()));
    }

    #[test]
    fn a_commit_that_is_not_deployed_yet_is_not_a_change() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        install(root, "org.example.Racer");
        deploy(root, "org.example.Racer", "aaaa");
        let before = fingerprint(root);
        let partial = root.join("app/org.example.Racer/x86_64/stable/bbbb/files");
        std::fs::create_dir_all(partial).unwrap();
        assert_eq!(before, fingerprint(root), "no deploy file yet");
    }

    #[test]
    fn a_hidden_checkout_directory_is_not_a_commit() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        install(root, "org.example.Racer");
        deploy(root, "org.example.Racer", "aaaa");
        let before = fingerprint(root);
        // Flatpak's temporary checkout; even a `deploy` file in it must not count.
        deploy(root, "org.example.Racer", ".bbbb-AbC123");
        assert_eq!(before, fingerprint(root));
    }

    #[cfg(unix)]
    #[test]
    fn moving_the_active_link_changes_the_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        install(root, "org.example.Racer");
        deploy(root, "org.example.Racer", "aaaa");
        deploy(root, "org.example.Racer", "bbbb");
        let branch = root.join("app/org.example.Racer/x86_64/stable");
        std::os::unix::fs::symlink("aaaa", branch.join("active")).unwrap();
        let on_a = fingerprint(root);
        assert!(on_a.contains(&"active/org.example.Racer/x86_64/stable=aaaa".to_owned()));
        std::fs::remove_file(branch.join("active")).unwrap();
        std::os::unix::fs::symlink("bbbb", branch.join("active")).unwrap();
        assert_ne!(
            on_a,
            fingerprint(root),
            "a rollback or an update moves `active`"
        );
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
