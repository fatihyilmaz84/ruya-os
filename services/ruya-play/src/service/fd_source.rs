//! The helper's opener inside its unit (Linux, RUY-829): the package is the one descriptor the
//! service manager opened as root and passed in (`OpenFile=`, [`crate::core::systemd_run`]). The
//! helper checks that the descriptor is the file or folder the service looked at (device and
//! inode in the descriptor's name), then reads a zip through the descriptor itself (a copy of it
//! per open, so no permission check of the dynamic uid applies) and a folder through
//! `/proc/self/fd/3` (its entries are then read with the helper's own rights).

use crate::core::deps::{OpenError, Opener};
use crate::core::systemd_run::{passed_source, LISTEN_FDS_START, SOURCE_IN_UNIT};
use ruya_play_format::{codes, FolderSource, Problem, Source, ZipSource};
use std::fs::File;
use std::os::fd::BorrowedFd;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// Opens the passed descriptor.
#[derive(Debug, Default, Clone, Copy)]
pub struct PassedFdOpener;

fn refuse(message: &str) -> OpenError {
    OpenError::Problems(vec![Problem::new(codes::PACKAGE_READ_FAILED, "", message)])
}

impl Opener for PassedFdOpener {
    fn open(&self, path: &Path) -> Result<Box<dyn Source + '_>, OpenError> {
        if path != Path::new(SOURCE_IN_UNIT) {
            return Err(refuse("The helper was asked for a path it was not given."));
        }
        let env = |k: &str| std::env::var(k).ok();
        let Some((fd, dev, ino)) = passed_source(
            std::process::id(),
            env("LISTEN_PID").as_deref(),
            env("LISTEN_FDS").as_deref(),
            env("LISTEN_FDNAMES").as_deref(),
        ) else {
            // `graceful`: the manager found nothing at the path.
            return Err(OpenError::Missing);
        };
        debug_assert_eq!(fd, LISTEN_FDS_START);
        // SAFETY: systemd passed exactly one descriptor at LISTEN_FDS_START to this process
        // (LISTEN_PID and LISTEN_FDS were checked above); it stays open for the whole run.
        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        let file = borrowed
            .try_clone_to_owned()
            .map(File::from)
            .map_err(|e| refuse(&format!("The package could not be opened ({e}).")))?;
        let meta = file
            .metadata()
            .map_err(|e| refuse(&format!("The package could not be opened ({e}).")))?;
        if meta.dev() != dev || meta.ino() != ino {
            return Err(refuse(
                "The package changed between the service's look and the helper's open.",
            ));
        }
        if meta.is_dir() {
            return Ok(Box::new(FolderSource::new(format!("/proc/self/fd/{fd}"))));
        }
        if !meta.is_file() {
            return Err(refuse("The package is a special file, not a package."));
        }
        let zip = ZipSource::new(std::io::BufReader::new(file)).map_err(OpenError::Problems)?;
        Ok(Box::new(zip))
    }
}
