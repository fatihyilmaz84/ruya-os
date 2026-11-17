//! Revocation through the `[packages]` section of the store blocklist (05 §9.2, Q6).

mod common;

use common::*;
use ruya_play_trust::keys::sha256_hex;
use ruya_play_trust::revocation::{BuildRange, Entry};
use ruya_play_trust::{
    inspect, is_revoked, select_blocklist, sign_blocklist, Blocklist, Context, ListSource,
    PackageFacts, RevokedBy, TrustError,
};

const H1: &str = "1111111111111111111111111111111111111111111111111111111111111111";

fn facts() -> PackageFacts {
    PackageFacts {
        id: "com.example.mini".into(),
        build: 7,
        key_ids: vec!["0123456789abcdef".into()],
        play_files_sha256: H1.into(),
    }
}

fn list(packages: &str) -> Blocklist {
    Blocklist::parse(format!("serial 1\n[packages]\n{packages}").as_bytes()).unwrap()
}

fn revoked_by(list: &Blocklist, runners: &[String]) -> Option<RevokedBy> {
    match is_revoked(list, &facts(), runners) {
        Some(TrustError::Revoked { by, .. }) => Some(by),
        Some(other) => panic!("{other:?}"),
        None => None,
    }
}

#[test]
fn the_file_reads_as_specified() {
    let text = format!(
        "# RuyaOS store blocklist\n\nserial 12\n[stores]\nfingerprint abc A store we do not read here\n[packages]\n\
         key 0123456789abcdef The key was stolen\r\n\
         id com.Example.Game 1-142 Builds up to 142 carry malware\n\
         content {H1} Known malware\n\
         runner {} Wine 8.0 has a sandbox escape\n\
         someday-kind 42 A kind this console does not know\n",
        "2".repeat(64)
    );
    let l = Blocklist::parse(text.as_bytes()).unwrap();
    assert_eq!(l.serial, 12);
    assert_eq!(
        l.entries,
        vec![
            (
                Entry::Key("0123456789abcdef".into()),
                "The key was stolen".into()
            ),
            (
                Entry::Id("com.example.game".into(), BuildRange { from: 1, to: 142 }),
                "Builds up to 142 carry malware".into()
            ),
            (Entry::Content(H1.into()), "Known malware".into()),
            (
                Entry::Runner("2".repeat(64)),
                "Wine 8.0 has a sandbox escape".into()
            ),
        ]
    );
    assert_eq!(
        Blocklist::parse(b"").unwrap(),
        Blocklist::default(),
        "empty at first"
    );
}

#[test]
fn build_ranges() {
    let r = |s| BuildRange::parse(s);
    assert_eq!(
        r("*"),
        Some(BuildRange {
            from: 0,
            to: u64::MAX
        })
    );
    assert_eq!(r("7"), Some(BuildRange { from: 7, to: 7 }));
    assert_eq!(r("3-9"), Some(BuildRange { from: 3, to: 9 }));
    assert_eq!(
        r("3-"),
        Some(BuildRange {
            from: 3,
            to: u64::MAX
        })
    );
    for bad in [
        "",
        "-3",
        "9-3",
        "a",
        "1-b",
        "+1",
        "1--2",
        "99999999999999999999",
    ] {
        assert_eq!(r(bad), None, "{bad}");
    }
    let range = r("3-9").unwrap();
    assert!(range.contains(3) && range.contains(9) && !range.contains(2) && !range.contains(10));
}

#[test]
fn malformed_lists_are_errors() {
    for (what, text) in [
        (
            "short key id",
            "serial 1\n[packages]\nkey 0123 x\n".to_string(),
        ),
        (
            "upper-case key id",
            "[packages]\nkey 0123456789ABCDEF x\n".into(),
        ),
        ("no reason", "[packages]\nkey 0123456789abcdef\n".into()),
        ("bad range", "[packages]\nid com.example.a 9-3 x\n".into()),
        ("no range", "[packages]\nid com.example.a\n".into()),
        ("bad hash", "[packages]\ncontent 1234 x\n".into()),
        ("serial twice", "serial 1\nserial 2\n".into()),
        ("serial text", "serial one\n".into()),
        (
            "control character",
            "[packages]\nkey 0123456789abcdef x\u{1b}[2J\n".into(),
        ),
        (
            "long reason",
            format!("[packages]\nkey 0123456789abcdef {}\n", "x".repeat(201)),
        ),
    ] {
        let e = Blocklist::parse(text.as_bytes()).unwrap_err();
        assert_eq!(e.code(), "blocklist.malformed", "{what}");
    }
    assert_eq!(
        Blocklist::parse(b"\xff").unwrap_err().code(),
        "blocklist.malformed"
    );
    let big = vec![b'#'; 4 * 1024 * 1024 + 1];
    assert_eq!(
        Blocklist::parse(&big).unwrap_err().code(),
        "blocklist.malformed"
    );
}

#[test]
fn a_revocation_by_key_matches() {
    assert_eq!(
        revoked_by(&list("key 0123456789abcdef x\n"), &[]),
        Some(RevokedBy::Key)
    );
    assert_eq!(revoked_by(&list("key fedcba9876543210 x\n"), &[]), None);
}

#[test]
fn a_revocation_by_id_and_build_range_matches() {
    assert_eq!(
        revoked_by(&list("id COM.EXAMPLE.MINI 1-7 x\n"), &[]),
        Some(RevokedBy::Id)
    );
    assert_eq!(
        revoked_by(&list("id com.example.mini * x\n"), &[]),
        Some(RevokedBy::Id)
    );
    assert_eq!(revoked_by(&list("id com.example.mini 8- x\n"), &[]), None);
    assert_eq!(revoked_by(&list("id com.example.other * x\n"), &[]), None);
}

#[test]
fn a_revocation_by_content_hash_matches() {
    assert_eq!(
        revoked_by(&list(&format!("content {H1} x\n")), &[]),
        Some(RevokedBy::Content)
    );
    assert_eq!(
        revoked_by(&list(&format!("content {} x\n", "3".repeat(64))), &[]),
        None
    );
}

#[test]
fn a_revocation_by_runner_hash_matches() {
    let l = list(&format!("runner {} Old Wine\n", "4".repeat(64)));
    assert_eq!(revoked_by(&l, &["4".repeat(64)]), Some(RevokedBy::Runner));
    assert_eq!(revoked_by(&l, &["5".repeat(64)]), None);
    assert_eq!(revoked_by(&l, &[]), None);
    let Some(e) = is_revoked(&l, &facts(), &["4".repeat(64)]) else {
        panic!()
    };
    assert_eq!(e.code(), "revoked.runner");
    assert!(e.message().contains("Old Wine"));
}

#[test]
fn inspect_refuses_a_revoked_package() {
    let (console, dev) = (Console::new(), key());
    let pkg = Pkg::minimal().signed(&dev);
    let table = sha256_hex(&pkg.table());
    let runner = "6".repeat(64);
    for (entry, code) in [
        (
            format!("key {} stolen", dev.public().key_id()),
            "revoked.key",
        ),
        ("id com.example.mini 7 bad build".to_string(), "revoked.id"),
        (format!("content {table} malware"), "revoked.content"),
        (format!("runner {runner} escape"), "revoked.runner"),
    ] {
        let l = list(&format!("{entry}\n"));
        let r = inspect(
            &pkg.mem(),
            &Context {
                store_keys: &console.store_keys,
                trust: &console.trust,
                blocklist: Some(&l),
                runner_hashes: std::slice::from_ref(&runner),
                verify_content: true,
            },
        );
        assert_refused(&r, code);
    }
    // The store key of an official package can be revoked too.
    let official = pkg.countersigned(&console.store);
    let l = list(&format!(
        "key {} store key lost\n",
        console.store.public().key_id()
    ));
    let r = inspect(
        &official.mem(),
        &Context {
            store_keys: &console.store_keys,
            trust: &console.trust,
            blocklist: Some(&l),
            runner_hashes: &[],
            verify_content: true,
        },
    );
    assert_refused(&r, "revoked.key");
}

#[test]
fn a_newer_verified_download_is_used() {
    let console = Console::new();
    let image = list("");
    let text = b"serial 2\n[packages]\nkey 0123456789abcdef x\n";
    let sig = sign_blocklist(&console.store, text, now() - 60, now() + 86_400);
    let s = select_blocklist(image, Some((text, &sig)), &console.store_keys, now());
    assert_eq!(s.source, ListSource::Downloaded);
    assert_eq!(s.list.serial, 2);
    assert_eq!(s.set_aside, None);
}

#[test]
fn a_download_that_is_not_newer_is_set_aside() {
    let console = Console::new();
    let image = Blocklist::parse(b"serial 3\n").unwrap();
    for serial in [2, 3] {
        let text = format!("serial {serial}\n");
        let sig = sign_blocklist(&console.store, text.as_bytes(), now() - 60, now() + 86_400);
        let s = select_blocklist(
            image.clone(),
            Some((text.as_bytes(), &sig)),
            &console.store_keys,
            now(),
        );
        assert_eq!(s.source, ListSource::Image);
        assert_eq!(
            s.set_aside.unwrap().code(),
            "blocklist.not_newer",
            "serial {serial}"
        );
    }
}

#[test]
fn a_bad_download_falls_back_to_the_image_and_never_blocks() {
    let (console, other) = (Console::new(), key());
    let image = list("key fedcba9876543210 from the image\n");
    let text = b"serial 9\n";
    let cases = [
        sign_blocklist(&other, text, now() - 60, now() + 86_400),
        sign_blocklist(&console.store, b"serial 8\n", now() - 60, now() + 86_400),
        b"garbage".to_vec(),
    ];
    for sig in cases {
        let s = select_blocklist(
            image.clone(),
            Some((text, &sig)),
            &console.store_keys,
            now(),
        );
        assert_eq!(s.source, ListSource::Image);
        assert_eq!(s.list, image);
        assert!(s.set_aside.is_some());
    }
    let s = select_blocklist(image.clone(), None, &console.store_keys, now());
    assert_eq!((s.source, s.set_aside), (ListSource::Image, None));
}
