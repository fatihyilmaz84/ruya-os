use super::*;
use std::fs;

fn base() -> (tempfile::TempDir, Dir) {
    let tmp = tempfile::tempdir().expect("tmp");
    let dir = Dir::open(tmp.path()).expect("open");
    (tmp, dir)
}

#[test]
fn a_file_is_written_whole_and_replaced() {
    let (tmp, dir) = base();
    dir.write(Path::new("a/b/f.txt"), b"one").expect("write");
    dir.write(Path::new("a/b/f.txt"), b"two").expect("replace");
    assert_eq!(
        fs::read(tmp.path().join("a/b/f.txt")).expect("read"),
        b"two"
    );
    assert!(!tmp.path().join("a/b/f.txt.tmp").exists());
    assert!(dir.write(Path::new("../x"), b"x").is_err());
    assert!(dir.write(Path::new("/x"), b"x").is_err());
    assert!(dir.write(Path::new("./x"), b"x").is_err());
    assert!(dir.write(Path::new(""), b"x").is_err());
}

#[test]
fn the_temporary_file_is_the_name_with_tmp_added() {
    assert_eq!(temp_name(OsStr::new("config.vdf")), "config.vdf.tmp");
    assert_eq!(temp_name(OsStr::new("f")), "f.tmp");
}

#[test]
fn write_atomic_writes_in_a_trusted_folder() {
    let tmp = tempfile::tempdir().expect("tmp");
    let path = tmp.path().join("state.json");
    write_atomic(&path, b"{}").expect("write");
    write_atomic(&path, b"[]").expect("replace");
    assert_eq!(fs::read(&path).expect("read"), b"[]");
    assert!(!tmp.path().join("state.json.tmp").exists());
    assert!(write_atomic(&tmp.path().join("none/f"), b"x").is_err());
}

#[test]
fn a_read_is_capped_and_a_missing_file_is_not_found() {
    let (tmp, dir) = base();
    fs::write(tmp.path().join("f"), "12345").expect("file");
    assert_eq!(dir.read(Path::new("f"), 5).expect("read"), b"12345");
    let e = dir.read(Path::new("f"), 4).expect_err("too big");
    assert_eq!(e.kind(), io::ErrorKind::InvalidData);
    assert!(e.to_string().contains("bigger than 4 bytes"), "{e}");
    let e = dir.read(Path::new("none"), 5).expect_err("missing");
    assert_eq!(e.kind(), io::ErrorKind::NotFound);
    let e = dir.read(Path::new("no/f"), 5).expect_err("missing");
    assert_eq!(e.kind(), io::ErrorKind::NotFound);
    fs::create_dir(tmp.path().join("d")).expect("dir");
    let e = dir.read(Path::new("d"), 5).expect_err("a folder");
    assert!(e.to_string().contains("not a regular file"), "{e}");
}

#[test]
fn a_tree_is_copied_and_removed() {
    let (tmp, dir) = base();
    fs::create_dir_all(tmp.path().join("t/a/b")).expect("dirs");
    fs::write(tmp.path().join("t/a/b/f"), "x").expect("file");
    fs::write(tmp.path().join("t/g"), "y").expect("file");
    assert!(dir
        .copy(Path::new("t"), &dir, Path::new("c/d"), 8)
        .expect("copy"));
    assert_eq!(
        fs::read_to_string(tmp.path().join("c/d/a/b/f")).expect("read"),
        "x"
    );
    assert_eq!(
        fs::read_to_string(tmp.path().join("c/d/g")).expect("read"),
        "y"
    );
    // The folder itself (an empty `rel`), into another base.
    let other = tempfile::tempdir().expect("tmp");
    let t = dir.walk(Path::new("t")).expect("walk");
    let to = Dir::open(other.path()).expect("open");
    assert!(t
        .copy(Path::new(""), &to, Path::new("copy"), 8)
        .expect("copy"));
    assert!(other.path().join("copy/a/b/f").is_file());
    // Nothing at the source is no copy.
    assert!(!dir
        .copy(Path::new("none"), &dir, Path::new("x"), 8)
        .expect("copy"));
    assert!(!dir
        .copy(Path::new("no/ne"), &dir, Path::new("x"), 8)
        .expect("copy"));
    assert!(!tmp.path().join("x").exists());
    dir.remove(Path::new("c")).expect("remove");
    dir.remove(Path::new("t/g")).expect("remove a file");
    assert!(!tmp.path().join("c").exists());
    assert!(!tmp.path().join("t/g").exists());
    dir.remove(Path::new("none/x")).expect("nothing there");
    assert!(dir.remove(Path::new("")).is_err(), "never the base itself");
}

#[test]
fn a_tree_deeper_than_the_cap_is_refused() {
    let (tmp, dir) = base();
    let deep = ["d"; 5].join("/");
    fs::create_dir_all(tmp.path().join("t").join(&deep)).expect("dirs");
    let e = dir
        .copy(Path::new("t"), &dir, Path::new("c"), 4)
        .expect_err("too deep");
    assert!(e.to_string().contains("more than 4 folders deep"), "{e}");
    assert!(dir
        .copy(Path::new("t"), &dir, Path::new("c"), 5)
        .expect("copy"));
}

#[test]
fn make_dirs_makes_what_is_missing_and_refuses_a_file() {
    let (tmp, dir) = base();
    let made = dir.make_dirs(Path::new("a/b")).expect("make");
    assert_eq!(made.path(), tmp.path().join("a/b"));
    dir.make_dirs(Path::new("a/b/c")).expect("again");
    assert!(tmp.path().join("a/b/c").is_dir());
    fs::write(tmp.path().join("a/f"), "x").expect("file");
    let e = dir.make_dirs(Path::new("a/f/g")).expect_err("a file");
    assert!(e.to_string().contains("is not a folder"), "{e}");
}

#[test]
fn not_followed_survives_io() {
    let e = NotFollowed::error("/d/prefix");
    assert!(NotFollowed::is(&e));
    assert!(e.to_string().contains("is a link"), "{e}");
    assert!(!NotFollowed::is(&io::Error::other("x")));
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::mpsc;
    use std::time::Duration;

    fn mode(path: &Path) -> u32 {
        fs::symlink_metadata(path)
            .expect("meta")
            .permissions()
            .mode()
            & 0o777
    }

    fn is_link(path: &Path) -> bool {
        fs::symlink_metadata(path)
            .expect("meta")
            .file_type()
            .is_symlink()
    }

    fn mkfifo(path: &Path) {
        use rustix::fs::{mknodat, FileType, Mode, CWD};
        mknodat(CWD, path, FileType::Fifo, Mode::from_raw_mode(0o600), 0).expect("mkfifo");
    }

    /// `f` run on its own thread; a call that blocks fails the test instead of hanging it.
    fn within_a_second<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(f());
        });
        rx.recv_timeout(Duration::from_secs(1))
            .expect("the call blocked")
    }

    /// A FIFO planted where the file is expected is refused at once (no blocking open).
    #[test]
    fn a_planted_fifo_is_refused_without_blocking() {
        let tmp = tempfile::tempdir().expect("tmp");
        mkfifo(&tmp.path().join("config.vdf"));
        let base = tmp.path().to_path_buf();
        let err = within_a_second(move || {
            Dir::open(&base)
                .expect("open")
                .read(Path::new("config.vdf"), 1024)
                .expect_err("refused")
        });
        assert!(err.to_string().contains("not a regular file"), "{err}");
        let base = tmp.path().to_path_buf();
        let err = within_a_second(move || {
            Dir::open(&base)
                .expect("open")
                .open_file(Path::new("config.vdf"))
                .expect_err("refused")
        });
        assert!(err.to_string().contains("not a regular file"), "{err}");
    }

    #[test]
    fn a_copy_skips_a_fifo_without_blocking() {
        let tmp = tempfile::tempdir().expect("tmp");
        fs::create_dir(tmp.path().join("t")).expect("dir");
        fs::write(tmp.path().join("t/f"), "x").expect("file");
        mkfifo(&tmp.path().join("t/pipe"));
        let base = tmp.path().to_path_buf();
        within_a_second(move || {
            let dir = Dir::open(&base).expect("open");
            dir.copy(Path::new("t"), &dir, Path::new("c"), 8)
                .expect("copy")
        });
        assert!(tmp.path().join("c/f").is_file());
        assert!(fs::symlink_metadata(tmp.path().join("c/pipe")).is_err());
    }

    #[test]
    fn files_are_0600_and_made_folders_0700() {
        let (tmp, dir) = base();
        dir.write(Path::new("a/b/f.txt"), b"x").expect("write");
        assert_eq!(mode(&tmp.path().join("a/b/f.txt")), 0o600);
        assert_eq!(mode(&tmp.path().join("a")), 0o700);
        assert_eq!(mode(&tmp.path().join("a/b")), 0o700);
        dir.make_dirs(Path::new("m/n")).expect("make");
        assert_eq!(mode(&tmp.path().join("m")), 0o700);
        assert_eq!(mode(&tmp.path().join("m/n")), 0o700);
        let path = tmp.path().join("own.json");
        write_atomic(&path, b"{}").expect("write");
        assert_eq!(mode(&path), 0o600);
    }

    /// A link named `planted` (in `base`) to a victim file; then `f` is written. The victim
    /// is untouched and `f` is a plain file with the new bytes.
    fn writes_over_a_planted_link(planted: &str) {
        let tmp = tempfile::tempdir().expect("tmp");
        let victim = tmp.path().join("victim");
        fs::write(&victim, "keep").expect("victim");
        let base = tmp.path().join("base");
        fs::create_dir(&base).expect("base");
        symlink(&victim, base.join(planted)).expect("link");
        Dir::open(&base)
            .expect("open")
            .write(Path::new("f"), b"new")
            .expect("write");
        assert_eq!(fs::read_to_string(&victim).expect("read"), "keep");
        assert_eq!(fs::read(base.join("f")).expect("read"), b"new");
        assert!(!is_link(&base.join("f")));
        assert!(!base.join("f.tmp").exists());
    }

    #[test]
    fn a_planted_link_as_the_temporary_file_is_not_written_through() {
        writes_over_a_planted_link("f.tmp");
    }

    #[test]
    fn a_planted_link_as_the_file_is_replaced_not_followed() {
        writes_over_a_planted_link("f");
    }

    #[test]
    fn a_linked_folder_anywhere_below_the_base_is_refused() {
        let tmp = tempfile::tempdir().expect("tmp");
        let outside = tmp.path().join("elsewhere");
        fs::create_dir(&outside).expect("outside");
        let base = tmp.path().join("base");
        fs::create_dir_all(base.join("a")).expect("base");
        symlink(&outside, base.join("a/b")).expect("link");
        let dir = Dir::open(&base).expect("open");
        let err = dir.write(Path::new("a/b/c/f"), b"x").expect_err("refused");
        assert!(err.to_string().contains("is a link"), "{err}");
        assert!(NotFollowed::is(&err), "{err}");
        assert_eq!(fs::read_dir(&outside).expect("list").count(), 0);
        // A link at the first step too, and a file where a folder belongs.
        symlink(&outside, base.join("top")).expect("link");
        assert!(dir.write(Path::new("top/f"), b"x").is_err());
        fs::write(base.join("plain"), "x").expect("file");
        assert!(dir.write(Path::new("plain/f"), b"x").is_err());
        assert_eq!(fs::read_dir(&outside).expect("list").count(), 0);
    }

    #[test]
    fn reading_refuses_a_link_at_any_step() {
        let tmp = tempfile::tempdir().expect("tmp");
        let outside = tmp.path().join("elsewhere");
        fs::create_dir(&outside).expect("outside");
        fs::write(outside.join("f"), "secret").expect("file");
        let base = tmp.path().join("base");
        fs::create_dir(&base).expect("base");
        fs::write(base.join("own"), "mine").expect("own");
        symlink(&outside, base.join("dir")).expect("link");
        symlink(outside.join("f"), base.join("file")).expect("link");
        let dir = Dir::open(&base).expect("open");
        assert_eq!(dir.read(Path::new("own"), 64).expect("read"), b"mine");
        assert!(NotFollowed::is(
            &dir.read(Path::new("dir/f"), 64).expect_err("refused")
        ));
        assert!(NotFollowed::is(
            &dir.read(Path::new("file"), 64).expect_err("refused")
        ));
        let missing = dir.read(Path::new("none"), 64).expect_err("missing");
        assert_eq!(missing.kind(), io::ErrorKind::NotFound);
    }

    #[test]
    fn a_folder_as_the_temporary_file_is_an_error() {
        let (tmp, dir) = base();
        fs::create_dir(tmp.path().join("f.tmp")).expect("dir");
        assert!(dir.write(Path::new("f"), b"x").is_err());
    }

    /// A base with `a/b/f` and a folder `outside` with a secret, for the link tests below.
    struct Planted {
        tmp: tempfile::TempDir,
        dir: Dir,
    }

    impl Planted {
        fn new() -> Self {
            let tmp = tempfile::tempdir().expect("tmp");
            let outside = tmp.path().join("outside");
            fs::create_dir_all(outside.join("b")).expect("outside");
            fs::write(outside.join("b/f"), "secret").expect("secret");
            fs::write(outside.join("f"), "secret").expect("secret");
            fs::set_permissions(outside.join("b"), fs::Permissions::from_mode(0o751)).expect("m");
            let base = tmp.path().join("base");
            fs::create_dir(&base).expect("base");
            let dir = Dir::open(&base).expect("open");
            Planted { tmp, dir }
        }

        fn outside(&self) -> PathBuf {
            self.tmp.path().join("outside")
        }

        /// Make `rel` (below the base) a link to the outside folder; its folders are made.
        fn link(&self, rel: &str) {
            let at = self.tmp.path().join("base").join(rel);
            fs::create_dir_all(at.parent().expect("parent")).expect("dirs");
            symlink(self.outside(), at).expect("link");
        }

        /// The outside folder is as it was made.
        fn untouched(&self) {
            let out = self.outside();
            let mut names: Vec<_> = fs::read_dir(&out)
                .expect("list")
                .map(|e| e.expect("entry").file_name())
                .collect();
            names.sort();
            assert_eq!(names, ["b", "f"]);
            assert_eq!(fs::read_dir(out.join("b")).expect("list").count(), 1);
            assert_eq!(fs::read_to_string(out.join("b/f")).expect("read"), "secret");
            assert_eq!(fs::read_to_string(out.join("f")).expect("read"), "secret");
            assert_eq!(mode(&out.join("b")), 0o751, "no mode set through a link");
        }
    }

    /// Each call meets a link at the first component and at a middle one, and refuses it
    /// ([`NotFollowed`]) without reaching what it points at.
    #[test]
    fn a_link_at_any_component_is_refused_by_every_call() {
        for at in ["l", "m/l"] {
            let p = Planted::new();
            p.link(at);
            let rel = |rest: &str| PathBuf::from(format!("{at}/{rest}"));
            let d = &p.dir;
            let refused = |r: io::Result<()>, what: &str| {
                let e = r.expect_err(what);
                assert!(NotFollowed::is(&e), "{what} at {at}: {e}");
            };
            refused(d.read(&rel("b/f"), 64).map(drop), "read");
            refused(d.open_file(&rel("f")).map(drop), "open");
            refused(d.write(&rel("b/f"), b"x"), "write");
            refused(d.write(&rel("new/f"), b"x"), "write into a new folder");
            refused(d.make_dirs(&rel("b/c")).map(drop), "make_dirs");
            refused(d.remove(&rel("b")), "remove");
            refused(
                d.copy(&rel("b"), d, Path::new("copy"), 8).map(drop),
                "copy from",
            );
            fs::create_dir_all(p.tmp.path().join("base/src")).expect("src");
            fs::write(p.tmp.path().join("base/src/f"), "mine").expect("src");
            refused(
                d.copy(Path::new("src"), d, &rel("b"), 8).map(drop),
                "copy to",
            );
            refused(d.symlink(Path::new("/"), &rel("b/z")), "symlink");
            p.untouched();
            assert!(!p.tmp.path().join("base/copy").exists());
        }
    }

    /// The race the handles close: the folder is opened, then swapped for a link to somewhere
    /// else. A write through the open folder lands in the folder that was opened (now moved
    /// aside), never behind the link; a new walk refuses the link.
    #[test]
    fn a_folder_swapped_for_a_link_cannot_redirect_a_write() {
        let p = Planted::new();
        let base = p.tmp.path().join("base");
        let held = p.dir.make_dirs(Path::new("saves/slot")).expect("make");
        // Swapped between the walk and the write.
        fs::rename(base.join("saves"), base.join("moved")).expect("move aside");
        symlink(p.outside(), base.join("saves")).expect("link");
        held.write(Path::new("f"), b"mine").expect("write");
        held.write(Path::new("b/f"), b"mine").expect("write below");
        assert_eq!(
            fs::read_to_string(base.join("moved/slot/f")).expect("read"),
            "mine"
        );
        assert_eq!(
            fs::read_to_string(base.join("moved/slot/b/f")).expect("read"),
            "mine"
        );
        p.untouched();
        let e = p
            .dir
            .write(Path::new("saves/slot/f"), b"x")
            .expect_err("a new walk refuses");
        assert!(NotFollowed::is(&e), "{e}");
        // The removal of a held folder is not redirected either.
        let held = p.dir.walk(Path::new("moved")).expect("walk");
        fs::rename(base.join("moved"), base.join("moved2")).expect("move aside");
        symlink(p.outside(), base.join("moved")).expect("link");
        held.remove(Path::new("slot")).expect("remove");
        assert!(!base.join("moved2/slot").exists());
        p.untouched();
    }

    /// A link inside a removed tree is removed, its target kept; a read-only folder is emptied.
    #[test]
    fn remove_takes_a_link_away_not_its_target() {
        let p = Planted::new();
        let base = p.tmp.path().join("base");
        fs::create_dir_all(base.join("t/ro")).expect("dirs");
        fs::write(base.join("t/ro/f"), "x").expect("file");
        symlink(p.outside(), base.join("t/l")).expect("link");
        symlink(p.outside().join("f"), base.join("t/ro/fl")).expect("link");
        fs::set_permissions(base.join("t/ro"), fs::Permissions::from_mode(0o555)).expect("ro");
        p.dir.remove(Path::new("t")).expect("remove");
        assert!(!base.join("t").exists());
        p.untouched();
        // A link as the thing removed: the link goes, not the target.
        symlink(p.outside(), base.join("top")).expect("link");
        p.dir.remove(Path::new("top")).expect("remove");
        assert!(fs::symlink_metadata(base.join("top")).is_err());
        p.untouched();
    }

    /// Modes are kept (a read-only folder too), a link is made again as a link with the same
    /// target, and replacing a link at the destination never follows it.
    #[test]
    fn a_copy_keeps_modes_and_links_as_links() {
        let p = Planted::new();
        let base = p.tmp.path().join("base");
        fs::create_dir_all(base.join("t/ro")).expect("dirs");
        fs::write(base.join("t/ro/f"), "x").expect("file");
        fs::set_permissions(base.join("t/ro/f"), fs::Permissions::from_mode(0o640)).expect("m");
        symlink("../drive_c", base.join("t/c:")).expect("link");
        symlink(p.outside(), base.join("t/out")).expect("link");
        fs::set_permissions(base.join("t/ro"), fs::Permissions::from_mode(0o555)).expect("ro");
        // A link where the copy goes (and where a file of it goes): replaced, not followed.
        fs::create_dir_all(base.join("c")).expect("dst");
        symlink(p.outside(), base.join("c/ro")).expect("link");
        assert!(p
            .dir
            .copy(Path::new("t"), &p.dir, Path::new("c"), 8)
            .expect("copy"));
        assert_eq!(fs::read_to_string(base.join("c/ro/f")).expect("read"), "x");
        assert_eq!(mode(&base.join("c/ro")), 0o555);
        assert_eq!(mode(&base.join("c/ro/f")), 0o640);
        assert!(is_link(&base.join("c/c:")));
        assert_eq!(
            fs::read_link(base.join("c/c:")).expect("link"),
            Path::new("../drive_c")
        );
        assert_eq!(
            fs::read_link(base.join("c/out")).expect("link"),
            p.outside()
        );
        p.untouched();
        p.dir.remove(Path::new("c")).expect("remove");
        p.dir.remove(Path::new("t")).expect("remove");
        p.untouched();
    }
}
