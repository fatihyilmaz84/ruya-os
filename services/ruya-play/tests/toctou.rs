//! RUY-99 acceptance: a link planted in the staging directory by a concurrent actor, between two
//! steps of the unpacker, does not make it write outside staging (05 §9.1, "TOCTOU between verify
//! and use"). The unpacker opens every folder with `O_DIRECTORY | O_NOFOLLOW` from its parent's
//! handle and creates every file with `O_CREAT | O_EXCL | O_NOFOLLOW`, so a planted link is an
//! error (`staging.changed`, status `failed`), and a folder swapped after it was opened keeps
//! receiving the files inside staging, where the re-walk finds the swap.
//!
//! Unix only: the Windows staging type is a checked path, not a handle, and is not race-free (it
//! is for development; the service runs on Linux). These run in CI on Linux and in the VM queue
//! (`vm-play-check.sh`, RUY-100).

mod common;

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: O_NOFOLLOW directory handles (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn a_link_planted_where_a_folder_goes_is_not_followed() {
    #[cfg(unix)]
    unix::planted(
        |s| matches!(s, ruya_play::Step::StagingCreated { .. }),
        |tree, outside| std::os::unix::fs::symlink(outside, tree.join("payload")).unwrap(),
    );
}

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: O_CREAT | O_EXCL | O_NOFOLLOW (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn a_link_planted_where_the_next_file_goes_is_not_followed() {
    #[cfg(unix)]
    unix::planted(
        |s| matches!(s, ruya_play::Step::Written { path } if *path == "payload/data.bin"),
        |tree, outside| {
            std::os::unix::fs::symlink(outside.join("game"), tree.join("payload").join("game"))
                .unwrap()
        },
    );
}

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: open folder handles (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn a_folder_swapped_for_a_link_keeps_the_files_inside_staging() {
    #[cfg(unix)]
    unix::planted(
        |s| matches!(s, ruya_play::Step::Written { path } if *path == "payload/data.bin"),
        |tree, outside| {
            std::fs::rename(tree.join("payload"), tree.join("payload.old")).unwrap();
            std::os::unix::fs::symlink(outside, tree.join("payload")).unwrap();
        },
    );
}

#[test]
#[cfg_attr(
    not(unix),
    ignore = "Unix only: an exclusive mkdirat (runs in CI on Linux and in the VM queue, vm-play-check.sh, RUY-100)"
)]
fn a_link_planted_as_the_job_directory_is_not_used() {
    #[cfg(unix)]
    unix::planted_job_dir();
}

#[cfg(unix)]
mod unix {
    use super::common::*;
    use ruya_play::core::fakes::FnHooks;
    use ruya_play::{JobStatus, Step};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};

    /// Install the game; at the first step `at` accepts, run `act(tree, outside)` once. Then the
    /// job must fail with `staging.changed`, nothing may be written outside, and nothing may be
    /// left in staging.
    pub fn planted(at: fn(&Step<'_>) -> bool, act: fn(&Path, &Path)) {
        let job_dir: Arc<Mutex<Option<PathBuf>>> = Arc::default();
        let done = Arc::new(Mutex::new(false));
        let (d, once) = (Arc::clone(&job_dir), Arc::clone(&done));
        let mut setup = Setup::with(Pkg::signed(&game()));
        setup.hooks = Box::new(FnHooks(move |_job: &str, step: &Step<'_>| {
            if let Step::StagingCreated { dir } = step {
                *d.lock().unwrap() = Some(dir.to_path_buf());
            }
            let mut done = once.lock().unwrap();
            if !*done && at(step) {
                *done = true;
                let dir = d.lock().unwrap().clone().expect("staging exists");
                // <root>/staging/job-1 -> <root>/outside
                let outside = dir.parent().unwrap().parent().unwrap().join("outside");
                act(&dir.join("tree"), &outside);
            }
        }));
        let mut h = setup.build();
        std::fs::write(h.outside.join("keep"), b"x").unwrap();
        let r = h.install();
        assert!(*done.lock().unwrap(), "the actor never ran");
        assert_eq!(r.status, JobStatus::Failed, "{:?}", r.problems);
        assert_eq!(codes(&r), vec!["staging.changed"], "{:?}", r.problems);
        assert_eq!(
            listing(&h.outside),
            vec!["keep"],
            "something was written outside"
        );
        assert_eq!(std::fs::read(h.outside.join("keep")).unwrap(), b"x");
        h.assert_nothing_left();
    }

    pub fn planted_job_dir() {
        let staging: Arc<Mutex<Option<PathBuf>>> = Arc::default();
        let s = Arc::clone(&staging);
        let mut setup = Setup::with(Pkg::signed(&game()));
        setup.hooks = Box::new(FnHooks(move |job: &str, step: &Step<'_>| {
            if *step == Step::BeforeUnpack {
                let staging = s.lock().unwrap().clone().expect("set after build");
                let outside = staging.parent().unwrap().join("outside");
                std::os::unix::fs::symlink(outside, staging.join(job)).unwrap();
            }
        }));
        let mut h = setup.build();
        *staging.lock().unwrap() = Some(h.cfg.staging.clone());
        std::fs::write(h.outside.join("keep"), b"x").unwrap();
        let r = h.install();
        assert_eq!(r.status, JobStatus::Failed, "{:?}", r.problems);
        assert_eq!(codes(&r), vec!["staging.changed"], "{:?}", r.problems);
        assert_eq!(listing(&h.outside), vec!["keep"]);
        h.assert_nothing_left();
    }
}
