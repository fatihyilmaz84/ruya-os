//! The package source is read once and never trusted again (lead-29).
//!
//! `ruya_play_trust::inspect` reads `play.json` and `play.files` to verify the signatures, and then
//! `ruya_play_format::validate` reads them again to parse them; it also lists the entries twice. A
//! drive (or a FUSE file system) that answers the second read differently could have one set of
//! bytes verified and another parsed. [`ReadOnce`] wraps the source so the listing and the four
//! root files are read from it exactly once and every later read gets the same bytes; the
//! importer writes those same bytes into staging. Payload files are passed through: the unpacker
//! opens each one once.

use ruya_play_format::limits::{MAX_MANIFEST_BYTES, MAX_TABLE_BYTES};
use ruya_play_format::{Entry, Problem, ReadFault, Source};
use ruya_play_trust::envelope::MAX_SIG_FILE_BYTES;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::{self, Read};

/// A remembered read failure, replayed as the same error each time.
#[derive(Debug, Clone)]
struct Fault {
    kind: io::ErrorKind,
    message: String,
    problem: Option<Problem>,
}

impl Fault {
    fn of(e: &io::Error) -> Fault {
        Fault {
            kind: e.kind(),
            message: e.to_string(),
            problem: ReadFault::from_io(e).cloned(),
        }
    }

    fn replay(&self) -> io::Error {
        match &self.problem {
            Some(p) => ReadFault::into_io(p.clone()),
            None => io::Error::new(self.kind, self.message.clone()),
        }
    }
}

/// The most bytes kept of a root file: its limit plus one, so the reader still sees "too big".
fn root_limit(path: &str) -> Option<u64> {
    match path {
        "play.json" => Some(MAX_MANIFEST_BYTES),
        "play.files" => Some(MAX_TABLE_BYTES),
        "play.sig" | "store.sig" => Some(MAX_SIG_FILE_BYTES as u64),
        _ => None,
    }
}

type Listing = Result<Vec<Entry>, Vec<Problem>>;

/// A source whose listing and root files are read once.
pub struct ReadOnce<'a> {
    inner: &'a dyn Source,
    listing: RefCell<Option<Listing>>,
    roots: RefCell<BTreeMap<String, Result<Vec<u8>, Fault>>>,
}

impl<'a> ReadOnce<'a> {
    /// Wrap `inner`.
    pub fn new(inner: &'a dyn Source) -> Self {
        ReadOnce {
            inner,
            listing: RefCell::new(None),
            roots: RefCell::new(BTreeMap::new()),
        }
    }

    /// The bytes of the root file `name` as they were first read, if they were.
    pub fn root(&self, name: &str) -> Option<Vec<u8>> {
        match self.roots.borrow().get(name) {
            Some(Ok(bytes)) => Some(bytes.clone()),
            _ => None,
        }
    }

    fn read_root(&self, name: &str, limit: u64) -> Result<Vec<u8>, Fault> {
        let mut buf = Vec::new();
        let reader = self.inner.open(name).map_err(|e| Fault::of(&e))?;
        reader
            .take(limit + 1)
            .read_to_end(&mut buf)
            .map_err(|e| Fault::of(&e))?;
        Ok(buf)
    }
}

impl Source for ReadOnce<'_> {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        let mut listing = self.listing.borrow_mut();
        listing.get_or_insert_with(|| self.inner.entries()).clone()
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        let Some(limit) = root_limit(path) else {
            return self.inner.open(path);
        };
        let mut roots = self.roots.borrow_mut();
        let entry = roots
            .entry(path.to_string())
            .or_insert_with(|| self.read_root(path, limit));
        match entry {
            Ok(bytes) => Ok(Box::new(io::Cursor::new(bytes.clone()))),
            Err(f) => Err(f.replay()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    /// Answers every read of play.json with other bytes, like a hostile drive.
    struct Shifty {
        reads: Cell<u32>,
        lists: Cell<u32>,
    }

    impl Source for Shifty {
        fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
            self.lists.set(self.lists.get() + 1);
            Ok(vec![Entry {
                path: "play.json".into(),
                kind: ruya_play_format::EntryKind::File,
                size: 1,
            }])
        }
        fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
            assert_eq!(path, "play.json");
            self.reads.set(self.reads.get() + 1);
            Ok(Box::new(io::Cursor::new(vec![
                b'0' + self.reads.get() as u8,
            ])))
        }
    }

    fn read_all(s: &dyn Source, path: &str) -> Vec<u8> {
        let mut v = Vec::new();
        s.open(path).unwrap().read_to_end(&mut v).unwrap();
        v
    }

    #[test]
    fn root_files_and_the_listing_are_read_once() {
        let shifty = Shifty {
            reads: Cell::new(0),
            lists: Cell::new(0),
        };
        assert_ne!(
            read_all(&shifty, "play.json"),
            read_all(&shifty, "play.json")
        );
        let once = ReadOnce::new(&shifty);
        let first = read_all(&once, "play.json");
        assert_eq!(read_all(&once, "play.json"), first);
        assert_eq!(once.root("play.json"), Some(first));
        once.entries().unwrap();
        once.entries().unwrap();
        assert_eq!((shifty.reads.get(), shifty.lists.get()), (3, 1));
    }
}
