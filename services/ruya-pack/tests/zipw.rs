//! The zip writer: what the console's reader sees, stored, deflated and with ZIP64 fields.

use ruya_pack::zipw::{write_zip, Entry, FileSrc, Item, Options};
use ruya_play_format::{EntryKind, Source, ZipSource};
use std::io::{Cursor, Read};

fn file(name: &str, data: &[u8], executable: bool) -> Entry<'static> {
    Entry {
        name: name.into(),
        item: Item::File {
            src: FileSrc::Bytes(data.to_vec()),
            size: data.len() as u64,
            crc: None,
            executable,
        },
    }
}

fn entries() -> Vec<Entry<'static>> {
    vec![
        file("payload/b.bin", &vec![9u8; 5000], false),
        file("payload/run.sh", b"#!/bin/sh\n", true),
        file("payload/\u{00fc}ber.txt", "grüße".as_bytes(), false),
        file("payload/empty", b"", false),
        Entry {
            name: "payload/saves".into(),
            item: Item::Dir,
        },
        file("a.txt", b"first", false),
    ]
}

fn read(z: &ZipSource<Cursor<Vec<u8>>>, name: &str) -> Vec<u8> {
    let mut v = Vec::new();
    z.open(name).unwrap().read_to_end(&mut v).unwrap();
    v
}

fn check(opts: Options) -> Vec<u8> {
    let mut bytes = Vec::new();
    let n = write_zip(&mut bytes, entries(), opts).unwrap();
    assert_eq!(n as usize, bytes.len());
    let z = ZipSource::new(Cursor::new(bytes.clone())).unwrap_or_else(|p| panic!("{p:?}"));
    let listed = z.entries().unwrap();
    let names: Vec<&str> = listed.iter().map(|e| e.path.as_str()).collect();
    let mut sorted = names.clone();
    sorted.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    assert_eq!(names, sorted, "entries are written sorted");
    let kind = |n: &str| {
        listed
            .iter()
            .find(|e| e.path.trim_end_matches('/') == n)
            .unwrap()
            .kind
    };
    assert_eq!(kind("payload/saves"), EntryKind::Dir);
    assert_eq!(kind("payload/run.sh"), EntryKind::File);
    assert_eq!(read(&z, "payload/b.bin"), vec![9u8; 5000]);
    assert_eq!(read(&z, "payload/\u{00fc}ber.txt"), "grüße".as_bytes());
    assert_eq!(read(&z, "payload/empty"), b"");
    assert_eq!(read(&z, "a.txt"), b"first");
    bytes
}

#[test]
fn stored_and_deflated_zips_read_back() {
    let stored = check(Options::default());
    let deflated = check(Options {
        deflate: true,
        ..Options::default()
    });
    assert!(deflated.len() < stored.len());
    assert_eq!(
        stored,
        check(Options::default()),
        "the same entries give the same bytes"
    );
}

#[test]
fn zip64_fields_read_back_too() {
    // Entries "from 0 bytes" get ZIP64 local and central fields and a ZIP64 end record.
    let stored = check(Options {
        deflate: false,
        zip64_at: 0,
    });
    assert!(
        stored.windows(4).any(|w| w == [0x50, 0x4b, 0x06, 0x06]),
        "ZIP64 end record"
    );
    check(Options {
        deflate: true,
        zip64_at: 0,
    });
}

#[test]
fn a_file_that_changes_while_it_is_written_is_an_error() {
    let mut out = Vec::new();
    let e = Entry {
        name: "x".into(),
        item: Item::File {
            src: FileSrc::Bytes(b"abc".to_vec()),
            size: 5,
            crc: Some(0),
            executable: false,
        },
    };
    assert!(write_zip(&mut out, vec![e], Options::default()).is_err());
}
