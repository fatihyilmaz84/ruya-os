//! `inspect` reads the package once: what it verified is what the format validation parsed, even
//! when the drive answers a second read with other bytes (lead-29).

mod common;

use common::*;
use ruya_play_format::{Entry, MemorySource, Problem, Source};
use ruya_play_trust::{inspect, Context, ListCheck};
use serde_json::json;
use std::cell::Cell;
use std::io::{self, Read};

/// A drive that gives `play.json`, `play.files` and the listing once, then lies.
struct Shifty {
    honest: MemorySource,
    liar: MemorySource,
    lists: Cell<u32>,
    json_reads: Cell<u32>,
    files_reads: Cell<u32>,
}

impl Source for Shifty {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        self.lists.set(self.lists.get() + 1);
        self.pick(self.lists.get()).entries()
    }

    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        let counter = match path {
            "play.json" => &self.json_reads,
            "play.files" => &self.files_reads,
            _ => return self.honest.open(path),
        };
        counter.set(counter.get() + 1);
        self.pick(counter.get()).open(path)
    }
}

impl Shifty {
    fn pick(&self, read: u32) -> &MemorySource {
        if read == 1 {
            &self.honest
        } else {
            &self.liar
        }
    }
}

#[test]
fn inspect_reads_the_listing_and_the_signed_files_once() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal().signed(&dev);
    let mut other = pkg.clone();
    other.manifest["name"] = json!({"en": "Other"});
    other.table_after = Some(b"not the table".to_vec());
    let shifty = Shifty {
        honest: pkg.mem(),
        liar: other.mem(),
        lists: Cell::new(0),
        json_reads: Cell::new(0),
        files_reads: Cell::new(0),
    };
    let inspection = inspect(
        &shifty,
        &Context {
            store_keys: &console.store_keys,
            trust: &console.trust,
            blocklist: ListCheck::NotChecked,
            runner_hashes: &[],
            verify_content: true,
        },
    )
    .expect("the first version is signed, and it is the only one inspect saw");
    assert_eq!(inspection.package.manifest.name["en"], "Mini");
    assert_eq!(
        (
            shifty.lists.get(),
            shifty.json_reads.get(),
            shifty.files_reads.get()
        ),
        (1, 1, 1)
    );
}
