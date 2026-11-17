//! Opening a package path: a folder that holds `play.json`, or a `.play.zip` file (05 §2). The
//! path's own metadata is read without following a link: a link is not a package.

use crate::core::deps::{OpenError, Opener};
use ruya_play_format::{codes, FolderSource, Problem, Source, ZipSource};
use std::io;
use std::path::Path;

/// Opens folders and zips on disk.
#[derive(Debug, Default, Clone, Copy)]
pub struct DiskOpener;

fn not_a_package(path: &Path, what: &str) -> OpenError {
    OpenError::Problems(vec![Problem::new(
        codes::PACKAGE_READ_FAILED,
        "",
        format!("{} is {what}, not a package.", path.display()),
    )])
}

impl Opener for DiskOpener {
    fn open(&self, path: &Path) -> Result<Box<dyn Source + '_>, OpenError> {
        let meta = match std::fs::symlink_metadata(path) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(OpenError::Missing),
            Err(e) => {
                return Err(OpenError::Problems(vec![Problem::new(
                    codes::PACKAGE_READ_FAILED,
                    "",
                    format!("The package could not be opened ({e})."),
                )]))
            }
        };
        if meta.file_type().is_symlink() {
            return Err(not_a_package(path, "a link"));
        }
        if meta.is_dir() {
            return Ok(Box::new(FolderSource::new(path)));
        }
        if !meta.is_file() {
            return Err(not_a_package(path, "a special file"));
        }
        let file = std::fs::File::open(path).map_err(|e| {
            if e.kind() == io::ErrorKind::NotFound {
                OpenError::Missing
            } else {
                OpenError::Problems(vec![Problem::new(
                    codes::PACKAGE_READ_FAILED,
                    "",
                    format!("The package could not be opened ({e})."),
                )])
            }
        })?;
        let zip = ZipSource::new(io::BufReader::new(file)).map_err(OpenError::Problems)?;
        Ok(Box::new(zip))
    }
}
