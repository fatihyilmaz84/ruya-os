//! The origin markers of the devices `ruya-inputd` makes (06-input.md §3 rule 1, `origin`): one
//! empty file per input device, `/run/ruya-input/own/inputN`, which the udev rules test at every
//! event. Written right after the device is made, removed before it is destroyed, all of them
//! removed at start; a device whose marker cannot be written is destroyed again (own only when
//! marked). Plain files in the service's own RuntimeDirectory, so the order is tested on any host.

use std::fs;
use std::io;
use std::path::PathBuf;

use crate::origin::valid_sysname;

pub struct Marks {
    dir: PathBuf,
}

fn bad_name(sysname: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("{sysname:?} is not an input device name"),
    )
}

impl Marks {
    /// Starts with no marker at all: a device the service made before it restarted is gone with
    /// the descriptor that made it.
    pub fn wipe(dir: impl Into<PathBuf>) -> io::Result<Marks> {
        let dir = dir.into();
        match fs::remove_dir_all(&dir) {
            Ok(()) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err),
        }
        fs::create_dir_all(&dir)?;
        Ok(Marks { dir })
    }

    pub fn is_marked(&self, sysname: &str) -> bool {
        valid_sysname(sysname) && self.dir.join(sysname).is_file()
    }

    /// Makes a device (`make` returns it and its input device's name, `UI_GET_SYSNAME`) and marks
    /// it. A device that cannot be marked is handed to `destroy` and the error returned.
    pub fn make<T>(
        &self,
        make: impl FnOnce() -> io::Result<(T, String)>,
        destroy: impl FnOnce(T),
    ) -> io::Result<(T, String)> {
        let (device, sysname) = make()?;
        let marked = if valid_sysname(&sysname) {
            fs::write(self.dir.join(&sysname), b"")
        } else {
            Err(bad_name(&sysname))
        };
        match marked {
            Ok(()) => Ok((device, sysname)),
            Err(err) => {
                destroy(device);
                Err(io::Error::new(
                    err.kind(),
                    format!("marking {sysname} as ours failed: {err}"),
                ))
            }
        }
    }

    /// Removes the marker, then destroys the device (`destroy`): from now on udev calls the node
    /// foreign, and no later device can carry the name (the kernel never reuses it).
    pub fn unmake(&self, sysname: &str, destroy: impl FnOnce()) {
        if valid_sysname(sysname) {
            if let Err(err) = fs::remove_file(self.dir.join(sysname)) {
                if err.kind() != io::ErrorKind::NotFound {
                    eprintln!("ruya-inputd: removing the marker of {sysname} failed: {err}");
                }
            }
        }
        destroy();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn the_marker_is_written_after_the_device_is_made() {
        let dir = tempfile::tempdir().expect("dir");
        let marks = Marks::wipe(dir.path().join("own")).expect("wipe");
        let (device, sysname) = marks
            .make(
                || {
                    assert!(!marks.is_marked("input23"), "no marker before the device");
                    Ok((7, "input23".to_owned()))
                },
                |_| panic!("a marked device is not destroyed"),
            )
            .expect("made");
        assert_eq!((device, sysname.as_str()), (7, "input23"));
        assert!(marks.is_marked("input23"));
    }

    #[test]
    fn the_marker_is_removed_before_the_device_is_destroyed() {
        let dir = tempfile::tempdir().expect("dir");
        let marks = Marks::wipe(dir.path().join("own")).expect("wipe");
        marks
            .make(|| Ok(((), "input24".to_owned())), |_| {})
            .expect("made");
        let destroyed = Cell::new(false);
        marks.unmake("input24", || {
            assert!(!marks.is_marked("input24"), "the marker goes first");
            destroyed.set(true);
        });
        assert!(destroyed.get());
        assert!(!marks.is_marked("input24"));
    }

    #[test]
    fn every_marker_is_removed_at_start() {
        let dir = tempfile::tempdir().expect("dir");
        let own = dir.path().join("own");
        fs::create_dir_all(&own).expect("dir");
        fs::write(own.join("input5"), b"").expect("stale marker");
        let marks = Marks::wipe(&own).expect("wipe");
        assert!(!marks.is_marked("input5"));
        assert!(own.is_dir());
        // A missing directory is made.
        let fresh = Marks::wipe(dir.path().join("fresh")).expect("wipe");
        assert!(!fresh.is_marked("input1"));
        assert!(dir.path().join("fresh").is_dir());
    }

    #[test]
    fn a_device_that_cannot_be_marked_is_destroyed() {
        let dir = tempfile::tempdir().expect("dir");
        let marks = Marks::wipe(dir.path().join("own")).expect("wipe");
        let destroyed = Cell::new(false);
        let err = marks
            .make(|| Ok(((), "../x".to_owned())), |_| destroyed.set(true))
            .expect_err("an odd name is refused");
        assert!(err.to_string().contains("../x"), "{err}");
        assert!(destroyed.get());
        // The directory gone: the write fails, the device goes.
        fs::remove_dir_all(dir.path().join("own")).expect("rm");
        let destroyed = Cell::new(false);
        assert!(marks
            .make(|| Ok(((), "input9".to_owned())), |_| destroyed.set(true))
            .is_err());
        assert!(destroyed.get());
        assert!(!marks.is_marked("../x"));
    }
}
