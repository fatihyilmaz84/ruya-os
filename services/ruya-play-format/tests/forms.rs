//! The folder and the zip form of a package go through one rule set and give identical results.

mod common;

use ruya_play_format::Source;

use common::*;
use ruya_play_format::{
    validate, validate_folder, validate_zip_file, FolderSource, ValidateOptions,
};

#[test]
fn valid_wine_full_is_the_same_in_every_form() {
    let fx = Fx::wine_full();
    let from_memory = assert_valid(check(&fx));

    let dir = tempfile::tempdir().unwrap();
    fx.write_dir(dir.path());
    let from_folder = assert_valid(validate_folder(dir.path(), &ValidateOptions::default()));

    let from_stored_zip = assert_valid(check_zip(fx.zip()));

    let mut deflated = fx.zip_entries();
    for e in deflated.iter_mut() {
        if !e.name.ends_with('/') {
            e.method = 8;
        }
    }
    let from_deflated_zip = assert_valid(check_zip(write_zip(&deflated)));

    let wrapped: Vec<ZE> = {
        let mut v = vec![ZE::dir("Star Hopper.play")];
        v.extend(fx.zip_entries().into_iter().map(|mut e| {
            e.name = format!("Star Hopper.play/{}", e.name);
            e.local_name = Some(e.name.clone());
            e
        }));
        v
    };
    let from_wrapped_zip = assert_valid(check_zip(write_zip(&wrapped)));

    assert_eq!(from_memory, from_folder);
    assert_eq!(from_memory, from_stored_zip);
    assert_eq!(from_memory, from_deflated_zip);
    assert_eq!(from_memory, from_wrapped_zip);
}

#[test]
fn a_zip_file_on_disk_validates() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("Star-Hopper.play.zip");
    std::fs::write(&path, Fx::wine_full().zip()).unwrap();
    assert_valid(validate_zip_file(&path, &ValidateOptions::default()));
    let missing = validate_zip_file(dir.path().join("none.zip"), &ValidateOptions::default());
    assert_rejected(missing, "package.read_failed");
}

#[test]
fn the_same_faults_are_found_in_both_forms() {
    let mut fx = Fx::wine_full();
    fx.table_override = Some(Fx::wine_full().table());
    fx.files
        .iter_mut()
        .find(|(p, _)| p == "payload/StarHopper.exe")
        .unwrap()
        .1 = b"MZ EXE".to_vec(); // same length, other bytes
    let dir = tempfile::tempdir().unwrap();
    fx.write_dir(dir.path());
    let folder = validate_folder(dir.path(), &ValidateOptions::default());
    let zip = check_zip(fx.zip());
    assert_eq!(codes_of(&folder), codes_of(&zip));
    assert_rejected_at(folder, "package.hash_mismatch", "payload/StarHopper.exe");
    assert_rejected_at(zip, "package.hash_mismatch", "payload/StarHopper.exe");
}

#[test]
fn an_extra_file_and_a_missing_file_in_a_folder() {
    let fx = Fx::minimal();
    let dir = tempfile::tempdir().unwrap();
    fx.write_dir(dir.path());
    std::fs::write(dir.path().join("payload/extra.bin"), b"x").unwrap();
    std::fs::create_dir(dir.path().join("payload/empty")).unwrap();
    std::fs::remove_file(dir.path().join("art/icon.png")).unwrap();
    let r = validate_folder(dir.path(), &ValidateOptions::default());
    assert_rejected_at(r.clone(), "package.extra_file", "payload/extra.bin");
    assert_rejected_at(r.clone(), "package.extra_dir", "payload/empty");
    assert_rejected_at(r, "package.missing_file", "art/icon.png");
}

#[test]
fn folder_listing_reports_names_kinds_and_sizes_before_any_content() {
    let fx = Fx::minimal();
    let dir = tempfile::tempdir().unwrap();
    fx.write_dir(dir.path());
    let l = listing(&FolderSource::new(dir.path()));
    let names: Vec<&str> = l.iter().map(|e| e.0.as_str()).collect();
    assert_eq!(
        names,
        [
            "art",
            "art/icon.png",
            "payload",
            "payload/game",
            "play.files",
            "play.json"
        ]
    );
    assert_eq!(l[3].2, 18);
}

#[cfg(unix)]
#[test]
fn a_real_symlink_or_hard_link_in_a_folder_is_refused() {
    let fx = Fx::minimal();
    let dir = tempfile::tempdir().unwrap();
    fx.write_dir(dir.path());
    std::os::unix::fs::symlink("/etc/passwd", dir.path().join("payload/link")).unwrap();
    assert_rejected(
        validate_folder(dir.path(), &ValidateOptions::default()),
        "entry.symlink",
    );

    let dir = tempfile::tempdir().unwrap();
    fx.write_dir(dir.path());
    std::fs::hard_link(
        dir.path().join("payload/game"),
        dir.path().join("payload/game2"),
    )
    .unwrap();
    assert_rejected(
        validate_folder(dir.path(), &ValidateOptions::default()),
        "entry.hardlink",
    );
}

#[test]
fn validate_takes_any_source() {
    let fx = Fx::minimal();
    assert_valid(validate(&fx.mem(), &ValidateOptions::default()));
}

#[test]
fn an_unreadable_folder_and_a_folder_with_too_many_entries() {
    let missing = FolderSource::new("this/folder/does/not/exist");
    assert!(missing
        .entries()
        .unwrap_err()
        .iter()
        .any(|p| p.code == "folder.unreadable"));

    let dir = tempfile::tempdir().unwrap();
    for i in 0..3 {
        std::fs::write(dir.path().join(format!("f{i}")), b"x").unwrap();
    }
    let at_limit = FolderSource::new(dir.path()).with_max_entries(3);
    assert_eq!(at_limit.entries().unwrap().len(), 3);
    let over = FolderSource::new(dir.path()).with_max_entries(2);
    assert!(over
        .entries()
        .unwrap_err()
        .iter()
        .any(|p| p.code == "folder.too_many_entries"));
    assert_rejected(
        validate(&over, &ValidateOptions::default()),
        "folder.too_many_entries",
    );
}
