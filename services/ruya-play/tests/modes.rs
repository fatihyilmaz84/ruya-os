//! RUY-99 acceptance: the importer sets modes itself (05 §4.2). A file listed with `x:1` is 0755
//! after the unpack, every other file 0644, every folder 0755, and nothing has the setuid, setgid
//! or sticky bit, whatever the source's attributes (a folder on a stick, or a zip's Unix mode).
//!
//! Unix only (Windows has no such modes); these run in CI on Linux and in the VM queue
//! (`vm-play-check.sh`, RUY-100).

mod common;

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: file modes (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn a_folder_with_odd_modes_is_staged_0644_and_0755() {
    #[cfg(unix)]
    unix::folder();
}

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: file modes (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn a_zip_with_setuid_modes_is_staged_0644_and_0755() {
    #[cfg(unix)]
    unix::zip();
}

#[cfg(unix)]
mod unix {
    use super::common::*;
    use ruya_play::core::staging::Kind;
    use ruya_play::JobStatus;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;

    fn chmod(p: &Path, mode: u32) {
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[track_caller]
    fn assert_modes(h: &Harness) {
        let calls = h.commit.calls();
        assert_eq!(calls.len(), 1);
        let mut seen = Vec::new();
        for e in &calls[0].tree {
            assert_eq!(
                e.mode & 0o7000,
                0,
                "{} has a setuid, setgid or sticky bit",
                e.path
            );
            seen.push((e.path.as_str(), e.kind, e.mode));
        }
        assert_eq!(
            seen,
            vec![
                ("art", Kind::Dir, 0o755),
                ("art/icon.png", Kind::File, 0o644),
                ("payload", Kind::Dir, 0o755),
                ("payload/data.bin", Kind::File, 0o644),
                ("payload/game", Kind::File, 0o755),
            ]
        );
        // The copy the fake commit made keeps them: the executable is executable.
        let game = h.target.join("play.com.example.mini/payload/game");
        assert_eq!(
            std::fs::metadata(game).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }

    pub fn folder() {
        let fx = game();
        let src = tempfile::tempdir().unwrap();
        fx.write_dir(src.path());
        chmod(&src.path().join("payload/data.bin"), 0o4777);
        chmod(&src.path().join("payload/game"), 0o6700);
        chmod(&src.path().join("art/icon.png"), 0o1600);
        chmod(&src.path().join("payload"), 0o3777);
        let pkg = Pkg::Signed(
            Box::new(Pkg::Folder(src.path().to_path_buf())),
            std::sync::Arc::new(dev_key()),
            None,
        );
        let mut h = Setup::with(pkg).build();
        let r = h.install();
        assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
        assert_modes(&h);
    }

    pub fn zip() {
        let fx = game();
        let entries: Vec<ZE> = fx
            .zip_entries()
            .into_iter()
            .map(|e| match e.name.as_str() {
                "payload/data.bin" => e.mode(0o104777),
                "payload/game" => e.mode(0o106700),
                "art/icon.png" => e.mode(0o101600),
                _ => e,
            })
            .collect();
        let pkg = Pkg::Signed(
            Box::new(Pkg::Zip(write_zip(&entries))),
            std::sync::Arc::new(dev_key()),
            None,
        );
        let mut h = Setup::with(pkg).build();
        let r = h.install();
        assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
        assert_modes(&h);
    }
}
