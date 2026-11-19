//! One test per hostile fixture of RUY-92, each rejected with its own error code, plus the two valid
//! packages every hostile one is a one-change variation of.

mod common;

use common::*;
use ruya_play_format::{validate, EntryKind, ValidateOptions};
use serde_json::json;

// ----- valid ---------------------------------------------------------------------------------

#[test]
fn valid_minimal() {
    let p = assert_valid(check(&Fx::minimal()));
    assert_eq!(p.manifest.id, "com.example.mini");
    assert_eq!(p.manifest.run.launch_mode, "fullscreen");
    assert_eq!(p.files.len(), 2);
}

#[test]
fn valid_wine_full() {
    let p = assert_valid(check(&Fx::wine_full()));
    assert_eq!(p.manifest.build, 142);
    assert_eq!(p.manifest.run.discs, vec!["payload/disc1.iso"]);
    assert_eq!(
        p.manifest.components[0].bundled.as_ref().unwrap().path,
        "components/wine"
    );
    assert!(p.manifest.permissions.multiarch);
}

#[test]
fn installed_mb_is_computed_and_a_declared_value_is_ignored() {
    let fx = Fx::wine_full();
    let p = assert_valid(check(&fx));
    let total: u64 = fx.files.iter().map(|(_, d)| d.len() as u64).sum();
    assert_eq!(p.installed_bytes, total);
    assert_eq!(p.installed_mb(), 1);
    // The manifest says 4800; nothing complains and nothing uses it.
    assert_eq!(fx.manifest["requirements"]["installed_mb"], 4800);
}

// ----- names ---------------------------------------------------------------------------------

fn with_extra_file(path: &str) -> Fx {
    let mut fx = Fx::minimal();
    fx.file(path, b"x");
    fx
}

#[test]
fn path_traversal() {
    assert_rejected(
        check(&with_extra_file("payload/../../etc/passwd")),
        "path.traversal",
    );
}

#[test]
fn path_traversal_in_a_zip() {
    let mut z = Fx::minimal().zip_entries();
    z.push(ZE::file("payload/../../etc/passwd", b"x".to_vec()));
    assert_rejected(check_zip(write_zip(&z)), "path.traversal");
}

#[test]
fn absolute_path() {
    assert_rejected(check(&with_extra_file("/etc/passwd")), "path.absolute");
}

#[test]
fn backslash() {
    assert_rejected(
        check(&with_extra_file("payload\\evil.exe")),
        "path.backslash",
    );
}

#[test]
fn case_collision() {
    let mut fx = Fx::minimal();
    fx.file("payload/Data.bin", b"a")
        .file("payload/data.bin", b"b");
    assert_rejected(check(&fx), "path.case_collision");
}

#[test]
fn case_collision_through_a_shared_folder() {
    let mut fx = Fx::minimal();
    fx.file("Payload/extra", b"a");
    assert_rejected(check(&fx), "path.case_collision");
}

#[test]
fn reserved_name() {
    assert_rejected(
        check(&with_extra_file("payload/CON.txt")),
        "path.reserved_name",
    );
    assert_rejected(check(&with_extra_file("payload/nul")), "path.reserved_name");
    assert_rejected(
        check(&with_extra_file("payload/com1")),
        "path.reserved_name",
    );
}

#[test]
fn colon_in_a_name_trailing_dot_nfd_and_control_characters() {
    assert_rejected(check(&with_extra_file("payload/c:evil")), "path.colon");
    assert_rejected(
        check(&with_extra_file("payload/dot.")),
        "path.trailing_dot_space",
    );
    assert_rejected(
        check(&with_extra_file("payload/space ")),
        "path.trailing_dot_space",
    );
    assert_rejected(
        check(&with_extra_file("payload/e\u{0301}.bin")),
        "path.not_nfc",
    );
    assert_rejected(check(&with_extra_file("payload/bell\u{7}")), "path.control");
    assert_rejected(
        check(&with_extra_file("payload//twice")),
        "path.empty_component",
    );
    assert_rejected(check(&with_extra_file("payload/./here")), "path.dot");
}

// ----- special files and links ---------------------------------------------------------------

#[test]
fn symlink_in_zip() {
    let mut z = Fx::minimal().zip_entries();
    z.push(ZE::file("payload/link", b"../../etc/passwd".to_vec()).mode(0o120777));
    assert_rejected(check_zip(write_zip(&z)), "entry.symlink");
}

#[test]
fn hardlink() {
    let mut z = Fx::minimal().zip_entries();
    let target = z.iter().position(|e| e.name == "payload/game").unwrap();
    let mut alias = ZE::file("payload/game2", vec![]);
    alias.alias_of = Some(target);
    z.push(alias);
    assert_rejected(check_zip(write_zip(&z)), "entry.hardlink");
}

#[test]
fn device_node() {
    let mut z = Fx::minimal().zip_entries();
    z.push(ZE::file("payload/null", vec![]).mode(0o020666));
    assert_rejected(check_zip(write_zip(&z)), "entry.device");
    let mut z = Fx::minimal().zip_entries();
    z.push(ZE::file("payload/fifo", vec![]).mode(0o010644));
    assert_rejected(check_zip(write_zip(&z)), "entry.special");
}

#[test]
fn special_entries_are_refused_in_any_container() {
    let mut m = Fx::minimal().mem();
    m.add_entry("payload/dev", EntryKind::Device);
    assert!(validate(&m, &ValidateOptions::default()).is_err());
}

fn with_links(links: &[(&str, &str)], extra_files: &[&str]) -> Fx {
    let mut fx = Fx::minimal();
    for f in extra_files {
        fx.file(f, b"data");
    }
    fx.links = links
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect();
    fx
}

#[test]
fn link_escapes_tree() {
    let fx = with_links(&[("payload/l", "../../../etc/passwd")], &[]);
    assert_rejected_at(check(&fx), "link.escapes_tree", "payload/l");
}

#[test]
fn link_absolute_and_odd_targets() {
    assert_rejected(
        check(&with_links(&[("payload/l", "/etc/passwd")], &[])),
        "link.absolute",
    );
    assert_rejected(
        check(&with_links(&[("payload/l", "C:/Windows")], &[])),
        "link.absolute",
    );
    assert_rejected(
        check(&with_links(&[("payload/l", "a\\b")], &[])),
        "link.target_invalid",
    );
    assert_rejected(
        check(&with_links(&[("payload/l", "")], &[])),
        "link.target_invalid",
    );
    assert_rejected(
        check(&with_links(&[("payload/l", "a//b")], &[])),
        "link.target_invalid",
    );
}

#[test]
fn link_at_the_package_root_and_dangling() {
    assert_rejected(
        check(&with_links(&[("rootlink", "payload/game")], &[])),
        "link.at_root",
    );
    assert_rejected(
        check(&with_links(&[("payload/l", "nothing")], &[])),
        "link.dangling",
    );
}

fn chain(len: usize) -> Fx {
    let mut fx = Fx::minimal();
    fx.file("payload/lib/real.so", b"so");
    // l1 -> l2 -> ... -> l<len> -> real.so
    for i in 1..=len {
        let to = if i == len {
            "real.so".to_string()
        } else {
            format!("l{}", i + 1)
        };
        fx.links.push((format!("payload/lib/l{i}"), to));
    }
    fx
}

#[test]
fn link_chain_of_eight_hops_is_legal_and_nine_is_not() {
    assert_valid(check(&chain(8)));
    assert_rejected_at(check(&chain(9)), "link.chain_too_long", "payload/lib/l1");
}

#[test]
fn link_chain_too_long() {
    assert_rejected(check(&chain(12)), "link.chain_too_long");
}

#[test]
fn link_chain_leaves_top_dir() {
    let fx = with_links(&[("payload/a", "b"), ("payload/b", "../art/icon.png")], &[]);
    let r = check(&fx);
    assert_rejected_at(r, "link.leaves_top_dir", "payload/b");
}

#[test]
fn link_loop() {
    let fx = with_links(&[("payload/a", "b"), ("payload/b", "a")], &[]);
    assert_rejected(check(&fx), "link.loop");
}

#[test]
fn nothing_below_a_link_or_a_file() {
    let mut fx = with_links(&[("payload/dir", "../payload")], &["payload/dir/inner"]);
    assert_rejected(check(&fx), "link.as_parent");
    fx = Fx::minimal();
    fx.file("payload/game/inner", b"x");
    assert_rejected(check(&fx), "table.parent_not_dir");
}

// ----- zip container -------------------------------------------------------------------------

#[test]
fn duplicate_entry() {
    let mut z = Fx::minimal().zip_entries();
    z.push(ZE::file("payload/game", b"second".to_vec()));
    assert_rejected(check_zip(write_zip(&z)), "zip.duplicate_entry");
}

#[test]
fn encrypted_entry() {
    let mut z = Fx::minimal().zip_entries();
    z.iter_mut()
        .find(|e| e.name == "payload/game")
        .unwrap()
        .flags = 1;
    assert_rejected(check_zip(write_zip(&z)), "zip.encrypted");
}

#[test]
fn zip_bomb_ratio() {
    let mut fx = Fx::minimal();
    let zeros = vec![0u8; 8 * 1024 * 1024];
    fx.file("payload/bomb.bin", &zeros);
    let mut z = fx.zip_entries();
    z.iter_mut()
        .find(|e| e.name == "payload/bomb.bin")
        .unwrap()
        .method = 8;
    assert_rejected(check_zip(write_zip(&z)), "zip.ratio");
}

#[test]
fn declared_size_lies() {
    // The directory says 18 bytes (what the table says too); the content decompresses to far more.
    let mut fx = Fx::minimal();
    let big = vec![b'a'; 4096];
    fx.files
        .iter_mut()
        .find(|(p, _)| p == "payload/game")
        .unwrap()
        .1 = vec![b'a'; 18];
    let mut z = fx.zip_entries();
    let e = z.iter_mut().find(|e| e.name == "payload/game").unwrap();
    e.method = 8;
    e.precompressed = Some(deflate_for_test(&big));
    e.crc = Some(0);
    let r = check_zip(write_zip(&z));
    assert_rejected_at(r, "zip.declared_size_lies", "payload/game");
}

#[test]
fn declared_size_lies_when_short() {
    let mut fx = Fx::minimal();
    fx.files
        .iter_mut()
        .find(|(p, _)| p == "payload/game")
        .unwrap()
        .1 = vec![b'a'; 100];
    let mut z = fx.zip_entries();
    let e = z.iter_mut().find(|e| e.name == "payload/game").unwrap();
    e.method = 8;
    e.precompressed = Some(deflate_for_test(&[b'a'; 10]));
    e.crc = Some(0);
    assert_rejected(check_zip(write_zip(&z)), "zip.declared_size_lies");
}

fn deflate_for_test(data: &[u8]) -> Vec<u8> {
    use flate2::write::DeflateEncoder;
    use std::io::Write;
    let mut e = DeflateEncoder::new(Vec::new(), flate2::Compression::default());
    e.write_all(data).unwrap();
    e.finish().unwrap()
}

#[test]
fn zip_crc_must_match() {
    let mut z = Fx::minimal().zip_entries();
    z.iter_mut().find(|e| e.name == "payload/game").unwrap().crc = Some(0x1234_5678);
    assert_rejected(check_zip(write_zip(&z)), "zip.crc_mismatch");
}

#[test]
fn zip_local_header_must_agree_with_the_directory() {
    let mut z = Fx::minimal().zip_entries();
    z.iter_mut()
        .find(|e| e.name == "payload/game")
        .unwrap()
        .local_name = Some("payload/gamX".into());
    assert_rejected(check_zip(write_zip(&z)), "zip.local_mismatch");
}

#[test]
fn zip_with_a_comment_or_data_around_it_is_refused() {
    let mut bytes = Fx::minimal().zip();
    let n = bytes.len();
    bytes[n - 2] = 4; // comment length 4 ...
    bytes.extend(b"junk");
    assert_rejected(check_zip(bytes), "zip.trailing_data");

    let mut bytes = Fx::minimal().zip();
    bytes.extend(b"trailing garbage");
    assert_rejected(check_zip(bytes), "zip.trailing_data");
}

#[test]
fn zip_with_a_gap_between_entries_is_refused() {
    let mut z = Fx::minimal().zip_entries();
    z[2].pad_before = b"gap!".to_vec();
    assert_rejected(check_zip(write_zip(&z)), "zip.gap");
}

#[test]
fn zip_with_data_in_front_is_refused() {
    let mut z = Fx::minimal().zip_entries();
    z[0].pad_before = b"MZ prefix".to_vec();
    assert_rejected(check_zip(write_zip(&z)), "zip.leading_data");
}

#[test]
fn zip_entries_that_overlap_are_refused() {
    let mut z = Fx::minimal().zip_entries();
    z[2].cd_offset = Some(10);
    assert_rejected(check_zip(write_zip(&z)), "zip.overlap");
}

#[test]
fn zip_unknown_method_and_not_a_zip() {
    let mut z = Fx::minimal().zip_entries();
    z.iter_mut()
        .find(|e| e.name == "payload/game")
        .unwrap()
        .method = 12;
    assert_rejected(check_zip(write_zip(&z)), "zip.method");
    assert_rejected(
        check_zip(b"just some text, not a zip file at all".to_vec()),
        "zip.not_a_zip",
    );
    assert_rejected(check_zip(vec![]), "zip.not_a_zip");
}

#[test]
fn zip_with_one_top_level_folder_is_unwrapped() {
    let z: Vec<ZE> = Fx::minimal()
        .zip_entries()
        .into_iter()
        .map(|mut e| {
            e.name = format!("Mini.play/{}", e.name);
            e.local_name = Some(e.name.clone());
            e
        })
        .collect();
    let mut with_dir = vec![ZE::dir("Mini.play")];
    with_dir.extend(z);
    assert_valid(check_zip(write_zip(&with_dir)));
}

// ----- table against package -----------------------------------------------------------------

#[test]
fn extra_file_not_in_table() {
    let fx = Fx::minimal();
    let mut m = fx.mem();
    m.add_file("payload/surprise.exe", b"boo".to_vec());
    assert_rejected_at(
        validate(&m, &ValidateOptions::default()),
        "package.extra_file",
        "payload/surprise.exe",
    );
}

#[test]
fn extra_dir_not_in_table() {
    let mut m = Fx::minimal().mem();
    m.add_dir("payload/empty");
    assert_rejected(
        validate(&m, &ValidateOptions::default()),
        "package.extra_dir",
    );
}

#[test]
fn missing_file() {
    let mut promised = Fx::minimal();
    promised.file("payload/promised.bin", b"x");
    let mut fx = Fx::minimal();
    fx.table_override = Some(promised.table());
    assert_rejected_at(check(&fx), "package.missing_file", "payload/promised.bin");
}

#[test]
fn hash_mismatch() {
    // The table of the original, the bytes of a copy with the same length and other content.
    let mut fx = Fx::minimal();
    fx.table_override = Some(Fx::minimal().table());
    fx.files
        .iter_mut()
        .find(|(p, _)| p == "payload/game")
        .unwrap()
        .1 = b"#!/bin/sh
echo ho
"
    .to_vec();
    assert_rejected_at(check(&fx), "package.hash_mismatch", "payload/game");
}

#[test]
fn size_in_table_differs_from_package() {
    let mut fx = Fx::minimal();
    fx.table_override = Some(Fx::minimal().table());
    fx.files
        .iter_mut()
        .find(|(p, _)| p == "payload/game")
        .unwrap()
        .1
        .push(b'!');
    assert_rejected_at(check(&fx), "package.size_mismatch", "payload/game");
}

#[test]
fn links_are_data_so_a_real_entry_at_a_link_path_is_refused() {
    let fx = with_links(&[("payload/l", "game")], &[]);
    let mut m = fx.mem();
    m.add_file("payload/l", b"x".to_vec());
    assert_rejected(
        validate(&m, &ValidateOptions::default()),
        "package.kind_mismatch",
    );
}

#[test]
fn nothing_is_read_when_the_names_fail() {
    // `open` of a hostile name would fail the test: the validator must stop after the names pass.
    let mut m = Fx::minimal().mem();
    m.add_file_declaring("payload/../x", 1, vec![]);
    let r = validate(&m, &ValidateOptions::default());
    let codes = codes_of(&r);
    assert!(codes.contains(&"path.traversal".to_string()));
    assert!(!codes
        .iter()
        .any(|c| c == "package.hash_mismatch" || c == "package.read_failed"));
}

#[test]
fn verify_content_can_be_switched_off() {
    let fx = Fx::minimal();
    let mut real = Fx::minimal();
    real.files
        .iter_mut()
        .find(|(p, _)| p == "payload/game")
        .unwrap()
        .1 = b"#!/bin/sh\necho ho\n".to_vec();
    real.table_override = Some(fx.table());
    let opts = ValidateOptions {
        verify_content: false,
        ..Default::default()
    };
    assert_valid(validate(&real.mem(), &opts));
}

// ----- the metadata files --------------------------------------------------------------------

#[test]
fn manifest_too_big() {
    let mut fx = Fx::minimal();
    let mut text = serde_json::to_string(&fx.manifest).unwrap();
    text.push_str(&" ".repeat(1024 * 1024));
    fx.manifest_override = Some(text.into_bytes());
    assert_rejected(check(&fx), "manifest.too_big");
}

#[test]
fn json_too_deep() {
    let mut fx = Fx::minimal();
    let mut deep = json!("x");
    for _ in 0..13 {
        deep = json!([deep]);
    }
    fx.manifest["extra"] = deep;
    assert_rejected(check(&fx), "manifest.too_deep");
}

#[test]
fn manifest_must_be_json_utf8_and_an_object() {
    let mut fx = Fx::minimal();
    fx.manifest_override = Some(b"{ not json".to_vec());
    assert_rejected(check(&fx), "manifest.invalid_json");
    fx.manifest_override = Some(vec![0xff, 0xfe, 0x00]);
    assert_rejected(check(&fx), "manifest.not_utf8");
    fx.manifest_override = Some(b"[1,2]".to_vec());
    assert_rejected(check(&fx), "manifest.type");
}

#[test]
fn missing_manifest_and_table() {
    let mut m = ruya_play_format::MemorySource::new();
    m.add_file("play.files", vec![]);
    assert_rejected(
        validate(&m, &ValidateOptions::default()),
        "package.no_manifest",
    );
    let mut m = ruya_play_format::MemorySource::new();
    m.add_file("play.json", b"{}".to_vec());
    assert_rejected(
        validate(&m, &ValidateOptions::default()),
        "package.no_table",
    );
}

#[test]
fn table_rules() {
    let good = Fx::minimal().table();
    let text = String::from_utf8(good.clone()).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    let mut fx = Fx::minimal();

    fx.table_override = Some(format!("{}\n{}\n", lines[1], lines[0]).into_bytes());
    assert_rejected(check(&fx), "table.not_sorted");
    fx.table_override = Some(format!("{}\n{}\n{}\n", lines[0], lines[0], lines[1]).into_bytes());
    assert_rejected(check(&fx), "table.duplicate");
    fx.table_override = Some(format!("{}\n\n{}\n", lines[0], lines[1]).into_bytes());
    assert_rejected(check(&fx), "table.blank_line");
    fx.table_override = Some(format!("{}\r\n{}\r\n", lines[0], lines[1]).into_bytes());
    assert_rejected(check(&fx), "table.line_invalid");
    fx.table_override = Some(b"{\"p\":\"a\",\"t\":\"f\"}\n".to_vec());
    assert_rejected(check(&fx), "table.line_invalid");
    fx.table_override = Some(b"{\"p\":\"a\",\"t\":\"s\"}\n".to_vec());
    assert_rejected(check(&fx), "table.line_invalid");
    fx.table_override = Some(b"{\"p\":\"a\",\"t\":\"d\",\"extra\":1}\n".to_vec());
    assert_rejected(check(&fx), "table.line_invalid");
    fx.table_override = Some(
        format!(
            "{}\n{}\n",
            lines[0].replace("\"h\":\"", "\"h\":\"0"),
            lines[1]
        )
        .into_bytes(),
    );
    assert_rejected(check(&fx), "table.line_invalid");
    fx.table_override = Some(vec![0xff, 0xfe]);
    assert_rejected(check(&fx), "table.not_utf8");
    fx.table_override = Some(
        format!(
            "{}\n{}\n{{\"p\":\"play.json\",\"t\":\"d\"}}\n",
            lines[0], lines[1]
        )
        .into_bytes(),
    );
    assert_rejected(check(&fx), "table.reserved_path");
}

#[test]
fn reserved_top_level_names_are_refused_at_the_top_and_below_but_not_nested() {
    use ruya_play_format::table::RESERVED_TOP_LEVEL;
    assert_eq!(RESERVED_TOP_LEVEL, &[".ref", "launcher", "share"]);
    for name in RESERVED_TOP_LEVEL {
        // The name as a file, below it, and as an empty folder.
        let mut fx = Fx::minimal();
        fx.file(name, b"x");
        assert_rejected_at(check(&fx), "table.reserved_top_level", name);
        let below = format!("{name}/x");
        let mut fx = Fx::minimal();
        fx.file(&below, b"x");
        assert_rejected_at(check(&fx), "table.reserved_top_level", &below);
        let mut fx = Fx::minimal();
        fx.dirs.push(name.to_string());
        assert_rejected_at(check(&fx), "table.reserved_top_level", name);
        // Nested elsewhere, and a longer name that only starts the same, stay legal.
        let nested = format!("payload/{name}/x");
        let longer = format!("{name}s/x");
        let mut fx = Fx::minimal();
        fx.file(&nested, b"x");
        fx.file(&longer, b"x");
        assert!(check(&fx).is_ok(), "{nested} and {longer} are ordinary");
    }
}

// ----- manifest rules ------------------------------------------------------------------------

#[test]
fn unknown_permission_key() {
    let mut fx = Fx::minimal();
    fx.manifest["permissions"] = json!({"camera": true});
    assert_rejected_at(check(&fx), "permissions.unknown_key", "/permissions/camera");
}

#[test]
fn microphone_and_bluetooth_are_not_in_the_vocabulary_either() {
    for key in ["microphone", "bluetooth", "filesystem", "talk_name"] {
        let mut fx = Fx::minimal();
        fx.manifest["permissions"] = json!({ key: true });
        assert_rejected(check(&fx), "permissions.unknown_key");
    }
}

#[test]
fn unknown_run_key() {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["shell"] = json!("sh -c 'rm -rf /'");
    assert_rejected_at(check(&fx), "run.unknown_key", "/run/shell");
}

#[test]
fn unknown_keys_elsewhere_are_ignored() {
    let mut fx = Fx::minimal();
    fx.manifest["from_a_newer_tool"] = json!({"anything": [1, 2, 3]});
    fx.manifest["developer"] = json!({"name": "Dev", "twitter": "@dev"});
    assert_valid(check(&fx));
}

#[test]
fn format_from_the_future() {
    let mut fx = Fx::minimal();
    fx.manifest["format"] = json!(2);
    assert_rejected(check(&fx), "format.too_new");
    fx.manifest["format"] = json!(0);
    assert_rejected(check(&fx), "format.invalid");
    fx.manifest["format"] = json!("1");
    assert_rejected(check(&fx), "format.invalid");
}

#[test]
fn http_link() {
    let mut fx = Fx::minimal();
    fx.manifest["links"] = json!([{"kind": "homepage", "url": "http://example.com"}]);
    assert_rejected_at(check(&fx), "url.not_https", "/links/0/url");
    for bad in [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,x",
    ] {
        fx.manifest["links"] = json!([{"kind": "homepage", "url": bad}]);
        assert_rejected(check(&fx), "url.not_https");
    }
    for bad in [
        "https://",
        "https://user:pw@example.com/",
        "https://exa mple.com",
        "example.com",
    ] {
        fx.manifest["links"] = json!([{"kind": "homepage", "url": bad}]);
        assert_rejected(check(&fx), "url.invalid");
    }
}

#[test]
fn name_with_bidi_override() {
    let mut fx = Fx::minimal();
    fx.manifest["name"] = json!({"en": "Game\u{202E}exe.pdf"});
    assert_rejected_at(check(&fx), "text.bidi", "/name/en");
}

#[test]
fn invisible_and_markup_text_is_refused() {
    let mut fx = Fx::minimal();
    fx.manifest["name"] = json!({"en": "Ga\u{200B}me"});
    assert_rejected(check(&fx), "text.zero_width");
    fx.manifest["name"] = json!({"en": "Game\u{7}"});
    assert_rejected(check(&fx), "text.control");
    fx.manifest["name"] = json!({"en": "Mini"});
    fx.manifest["summary"] = json!({"en": "<b>Buy</b> now"});
    assert_rejected(check(&fx), "text.markup");
    fx.manifest["summary"] = json!({"en": "See https://example.com"});
    assert_rejected(check(&fx), "text.link");
    fx.manifest["summary"] = json!({"en": "two\nlines"});
    assert_rejected(check(&fx), "text.control");
    fx.manifest["summary"] = json!({"en": "1 < 2 and 3 > 2"});
    assert_valid(check(&fx));
}

#[test]
fn reserved_app_name() {
    for name in [
        "Settings",
        "settings",
        "RuyaOS",
        "The Store",
        "Home",
        "UPDATE",
        "Guide",
        "RuyaOS Settings",
    ] {
        let mut fx = Fx::minimal();
        fx.manifest["name"] = json!({ "en": name });
        let r = check(&fx);
        if name == "The Store" {
            assert_valid(r); // not exactly a system name
        } else {
            assert_rejected(r, "name.reserved");
        }
    }
    let mut fx = Fx::minimal();
    fx.manifest["name"] = json!({"en": "Settings"});
    let opts = ValidateOptions {
        official: true,
        ..Default::default()
    };
    assert_valid(validate(&fx.mem(), &opts));
}

#[test]
fn reserved_app_name_in_another_language() {
    let mut fx = Fx::minimal();
    fx.manifest["name"] = json!({"en": "Fine", "de": "Einstellungen RuyaOS"});
    assert_rejected(check(&fx), "name.reserved");
}

#[test]
fn ids() {
    let mut fx = Fx::minimal();
    for (id, code) in [
        ("game", "id.invalid"),
        ("com.game", "id.invalid"),
        ("com..game", "id.invalid"),
        ("com.1example.game", "id.invalid"),
        ("com.exa mple.game", "id.invalid"),
        ("com.example.ga\u{e9}me", "id.invalid"),
        ("org.ruyaos.settings", "id.reserved"),
        ("play.com.example", "id.reserved"),
    ] {
        fx.manifest["id"] = json!(id);
        assert_rejected(check(&fx), code);
    }
    fx.manifest["id"] = json!("com.example.my-game");
    assert_valid(check(&fx));
    fx.manifest["id"] = json!("org.ruyaos.settings");
    let opts = ValidateOptions {
        official: true,
        ..Default::default()
    };
    assert_valid(validate(&fx.mem(), &opts));
}

#[test]
fn flatpak_id_invalid() {
    // A dash is fine in the last part only: the app is installed as play.<id>.
    let mut fx = Fx::minimal();
    fx.manifest["id"] = json!("com.example-games.star");
    assert_rejected(check(&fx), "id.flatpak_invalid");
}

#[test]
fn reserved_app_name_is_not_applied_to_the_id() {
    let mut fx = Fx::minimal();
    fx.manifest["id"] = json!("com.example.settings");
    assert_valid(check(&fx));
}

// ----- run.env -------------------------------------------------------------------------------

fn with_env(name: &str, value: &str) -> Fx {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["env"] = json!({ name: value });
    fx
}

#[test]
fn env_wineprefix() {
    assert_rejected_at(
        check(&with_env("WINEPREFIX", "/tmp/prefix")),
        "env.reserved",
        "/run/env/WINEPREFIX",
    );
}

#[test]
fn env_vk_icd() {
    assert_rejected_at(
        check(&with_env("VK_ICD_FILENAMES", "/x.json")),
        "env.reserved",
        "/run/env/VK_ICD_FILENAMES",
    );
}

#[test]
fn env_steam_compat() {
    assert_rejected_at(
        check(&with_env("STEAM_COMPAT_DATA_PATH", "/x")),
        "env.reserved",
        "/run/env/STEAM_COMPAT_DATA_PATH",
    );
}

#[test]
fn env_ruya() {
    // The launcher's own variables (ADR-037) are not the package's to set.
    assert_rejected_at(
        check(&with_env("RUYA_RUNNER", "system")),
        "env.reserved",
        "/run/env/RUYA_RUNNER",
    );
}

#[test]
fn env_bad_name() {
    assert_rejected(
        check(&with_env("__GLX_VENDOR_LIBRARY_NAME", "mesa")),
        "env.bad_name",
    );
    assert_rejected(check(&with_env("lower", "x")), "env.bad_name");
    assert_rejected(check(&with_env("1ST", "x")), "env.bad_name");
    assert_rejected(check(&with_env("A-B", "x")), "env.bad_name");
}

#[test]
fn every_entry_of_the_env_deny_table_is_refused() {
    use ruya_play_format::limits::{ENV_DENY_EXACT, ENV_DENY_PREFIX};
    for name in ENV_DENY_EXACT {
        assert_rejected(check(&with_env(name, "x")), "env.reserved");
    }
    for p in ENV_DENY_PREFIX {
        assert_rejected(
            check(&with_env(&format!("{p}ANYTHING"), "x")),
            "env.reserved",
        );
    }
    for name in [
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "DISPLAY",
        "PATH",
        "HOME",
        "WAYLAND_DISPLAY",
        "SDL_VIDEODRIVER",
    ] {
        assert_rejected(check(&with_env(name, "x")), "env.reserved");
    }
}

#[test]
fn env_names_a_game_may_set() {
    for name in [
        "WINEDLLOVERRIDES",
        "WINEDEBUG",
        "DXVK_HUD",
        "VKD3D_CONFIG",
        "PROTON_USE_WINED3D",
        "MANGOHUD",
        "MY_GAME_OPTION",
        "TZ",
    ] {
        assert_valid(check(&with_env(name, "1")));
    }
    assert_rejected(
        check(&with_env("MY_OPTION", &"x".repeat(1025))),
        "env.bad_value",
    );
    assert_rejected(check(&with_env("MY_OPTION", "a\nb")), "env.bad_value");
}

// ----- discs, prefix, placeholders, components -----------------------------------------------

#[test]
fn prefix_template_dosdevices() {
    let mut fx = Fx::wine_full();
    fx.file("payload/prefix-template/dosdevices/z", b"x");
    assert_rejected_at(
        check(&fx),
        "prefix.dosdevices",
        "payload/prefix-template/dosdevices/z",
    );
    // A real template also has a colon in dosdevices/c:, which the path rules refuse first.
    let mut fx = Fx::wine_full();
    fx.file("payload/prefix-template/dosdevices/c:", b"x");
    assert_rejected(check(&fx), "path.colon");
    let mut fx = Fx::wine_full();
    fx.file("payload/prefix-template/DosDevices/z", b"x");
    assert_rejected(check(&fx), "prefix.dosdevices");
}

#[test]
fn prefix_template_must_exist() {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["prefix"]["template"] = json!("payload/nothing-here");
    assert_rejected(check(&fx), "prefix.template_missing");
}

#[test]
fn disc_not_in_table() {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["discs"] = json!(["payload/disc1.iso", "payload/disc2.iso"]);
    assert_rejected_at(check(&fx), "run.disc_not_in_table", "/run/discs/1");
}

#[test]
fn disc_placeholder_without_discs() {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["command"] = json!(["${payload}/game", "${disc}"]);
    assert_rejected(check(&fx), "run.disc_placeholder_without_discs");
    fx.manifest["run"]["discs"] = json!(["payload/game"]);
    assert_valid(check(&fx));
}

#[test]
fn discs_must_be_payload_files_and_distinct() {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["discs"] = json!(["art/icon.png"]);
    assert_rejected(check(&fx), "run.disc_path");
    fx.manifest["run"]["discs"] = json!(["payload/disc1.iso", "payload/disc1.iso"]);
    assert_rejected(check(&fx), "run.disc_duplicate");
}

#[test]
fn component_placeholder_and_runner_matching() {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["command"] = json!(["${component:nope}/bin/wine"]);
    assert_rejected(check(&fx), "run.placeholder_component");
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["component"] = json!("other");
    assert_rejected(check(&fx), "run.component_unknown");
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["runner"] = json!("proton");
    assert_rejected(check(&fx), "run.component_type");
    let mut fx = Fx::wine_full();
    fx.manifest["run"]
        .as_object_mut()
        .unwrap()
        .remove("component");
    assert_rejected(check(&fx), "run.component_missing");
    let mut fx = Fx::minimal();
    fx.manifest["run"]["component"] = json!("wine");
    assert_rejected(check(&fx), "run.component_unexpected");
}

#[test]
fn components_rules() {
    let mut fx = Fx::wine_full();
    fx.manifest["components"][0]
        .as_object_mut()
        .unwrap()
        .remove("min");
    assert_rejected(check(&fx), "component.missing_field");
    let mut fx = Fx::wine_full();
    fx.manifest["components"][0]
        .as_object_mut()
        .unwrap()
        .remove("bundled");
    assert_rejected(check(&fx), "component.missing_field");
    let mut fx = Fx::wine_full();
    fx.manifest["components"][0]["extra"] = json!(1);
    assert_rejected(check(&fx), "component.unknown_key");
    let mut fx = Fx::wine_full();
    fx.manifest["components"][0]["bundled"]["path"] = json!("components/none");
    assert_rejected(check(&fx), "component.bundled_missing");
    let mut fx = Fx::wine_full();
    fx.manifest["components"][0]["bundled"]["path"] = json!("payload");
    assert_rejected(check(&fx), "component.path");
    let mut fx = Fx::wine_full();
    let dup = fx.manifest["components"][0].clone();
    fx.manifest["components"].as_array_mut().unwrap().push(dup);
    assert_rejected(check(&fx), "component.duplicate");
}

#[test]
fn command_and_cwd() {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["command"] = json!(["${payload}/missing"]);
    assert_rejected(check(&fx), "run.command_missing");
    fx.manifest["run"]["command"] = json!("sh -c 'echo hi'");
    assert_rejected(check(&fx), "manifest.type");
    fx.manifest["run"]["command"] = json!([]);
    assert_rejected(check(&fx), "text.empty");
    fx.manifest["run"]["command"] = json!(["${payload}/game"]);
    fx.manifest["run"]["cwd"] = json!("/etc");
    assert_rejected(check(&fx), "run.cwd");
    fx.manifest["run"]["cwd"] = json!("${payload}/../..");
    assert_rejected(check(&fx), "run.cwd");
    fx.manifest["run"]["cwd"] = json!("${payload}/sub");
    assert_valid(check(&fx));
}

#[test]
fn setup_steps() {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["setup"][0]["shell"] = json!(true);
    assert_rejected(check(&fx), "run.unknown_key");
    let mut fx = Fx::wine_full();
    let step = fx.manifest["run"]["setup"][0].clone();
    fx.manifest["run"]["setup"]
        .as_array_mut()
        .unwrap()
        .push(step);
    assert_rejected(check(&fx), "list.duplicate");
}

#[test]
fn art_slots() {
    let mut fx = Fx::minimal();
    fx.manifest["art"]["icon"] = json!("payload/game");
    assert_rejected(check(&fx), "art.path");
    fx.manifest["art"]["icon"] = json!("art/missing.png");
    assert_rejected(check(&fx), "art.missing");
    fx.manifest["art"]["icon"] = json!("art/icon.svg");
    assert_rejected(check(&fx), "art.extension");
    fx.manifest["art"]["icon"] = json!("../art/icon.png");
    assert_rejected(check(&fx), "art.path");
    let mut fx = Fx::minimal();
    fx.manifest["art"].as_object_mut().unwrap().remove("icon");
    assert_rejected(check(&fx), "manifest.missing");
    let mut fx = Fx::minimal();
    fx.manifest.as_object_mut().unwrap().remove("art");
    assert_rejected(check(&fx), "manifest.missing");
    // An empty screenshots list is refused; leaving the key out is fine (05 section 5).
    let mut fx = Fx::minimal();
    fx.manifest["art"]["screenshots"] = json!([]);
    assert_rejected(check(&fx), "art.no_screenshots");
    fx.manifest["art"]
        .as_object_mut()
        .unwrap()
        .remove("screenshots");
    assert_valid(check(&fx));
}

#[test]
fn permissions_values_and_reasons() {
    let mut fx = Fx::minimal();
    fx.manifest["permissions"] = json!({"input": "everything"});
    assert_rejected(check(&fx), "value.unknown");
    fx.manifest["permissions"] = json!({"network": "yes"});
    assert_rejected(check(&fx), "manifest.type");
    fx.manifest["permissions"] = json!({"reasons": {"network": {"en": "x"}}});
    assert_valid(check(&fx));
    fx.manifest["permissions"] = json!({"reasons": {"camera": {"en": "x"}}});
    assert_rejected(check(&fx), "permissions.reason_key");
    fx.manifest["permissions"] = json!({"removable_media": "execute"});
    assert_rejected(check(&fx), "value.unknown");
}

#[test]
fn smaller_rules_of_the_manifest() {
    let cases: Vec<(&str, serde_json::Value, &str)> = vec![
        ("genres", json!(["nonsense"]), "value.unknown"),
        ("genres", json!(["action", "action"]), "list.duplicate"),
        ("controller", json!("kinda"), "value.unknown"),
        ("release_date", json!("2021-13-01"), "value.range"),
        ("languages", json!(["english"]), "lang.invalid"),
        ("name", json!({"fr": "Jeu"}), "lang.missing_en"),
        ("name", json!({"en": "A", "e n": "B"}), "lang.invalid"),
        ("build", json!(0), "value.range"),
        ("build", json!(1.5), "manifest.type"),
        ("version", json!(""), "text.empty"),
        ("players", json!({"min": 3, "max": 2}), "value.range"),
        ("age_rating", json!({"scheme": "esrb"}), "value.unknown"),
        (
            "age_rating",
            json!({"scheme": "oars-1.1", "content": {"violence": "extreme"}}),
            "value.unknown",
        ),
        (
            "licence",
            json!({"package": "not a licence!"}),
            "value.unknown",
        ),
        (
            "requirements",
            json!({"arch": "arm64"}),
            "requirements.arch",
        ),
        (
            "developer",
            json!({"url": "https://example.com"}),
            "manifest.missing",
        ),
        ("data", json!({"saves": ["../outside"]}), "data.path"),
        ("data", json!({"saves": ["data:../outside"]}), "data.path"),
        (
            "update",
            json!({"feed": "http://example.com/feed"}),
            "url.not_https",
        ),
        ("tags", json!(vec!["x"; 13]), "list.too_long"),
    ];
    for (key, value, code) in cases {
        let mut fx = Fx::minimal();
        fx.manifest[key] = value;
        assert_rejected(check(&fx), code);
    }
}

// ----- more container and listing rules --------------------------------------------------------

#[test]
fn an_empty_path_and_a_metadata_file_that_is_a_folder() {
    let mut m = Fx::minimal().mem();
    m.add_file("", b"x".to_vec());
    assert_rejected(validate(&m, &ValidateOptions::default()), "path.empty");

    let mut m = ruya_play_format::MemorySource::new();
    m.add_dir("play.json");
    m.add_file("play.files", vec![]);
    assert_rejected(
        validate(&m, &ValidateOptions::default()),
        "package.root_kind",
    );
}

#[test]
fn zip_names_must_be_utf8() {
    let mut z = Fx::minimal().zip_entries();
    let mut e = ZE::file("payload/xx", b"x".to_vec());
    e.name_bytes = Some(b"payload/\xff\xfe".to_vec());
    z.push(e);
    assert_rejected(check_zip(write_zip(&z)), "path.invalid_utf8");
}

#[test]
fn zip_split_over_disks_and_damaged_directories_are_refused() {
    let mut bytes = Fx::minimal().zip();
    let n = bytes.len();
    bytes[n - 22 + 4] = 1; // this disk is number 1
    assert_rejected(check_zip(bytes), "zip.multi_disk");

    // A stored entry whose compressed and real sizes differ.
    let mut z = Fx::minimal().zip_entries();
    z[2].declared_csize = Some(3);
    assert_rejected(check_zip(write_zip(&z)), "zip.malformed");
    // A directory with content.
    let mut z = Fx::minimal().zip_entries();
    let mut d = ZE::dir("payload/sub");
    d.data = b"x".to_vec();
    d.declared_usize = Some(1);
    d.declared_csize = Some(1);
    z.push(d);
    assert_rejected(check_zip(write_zip(&z)), "zip.malformed");
    // The central directory cut short.
    let mut bytes = Fx::minimal().zip();
    let n = bytes.len();
    let cd_size = u32::from_le_bytes(bytes[n - 10..n - 6].try_into().unwrap());
    bytes[n - 10..n - 6].copy_from_slice(&(cd_size - 10).to_le_bytes());
    assert_rejected(check_zip(bytes), "zip.malformed");
}

#[test]
fn zip_entries_with_a_data_descriptor_are_accepted() {
    let mut z = Fx::minimal().zip_entries();
    for e in z.iter_mut() {
        e.flags |= 8;
    }
    assert_valid(check_zip(write_zip(&z)));
    // ... but not with junk where the descriptor goes.
    let mut z = Fx::minimal().zip_entries();
    z[2].pad_before = vec![]; // keep offsets honest
    z[3].pad_before = b"12345".to_vec();
    assert_rejected(check_zip(write_zip(&z)), "zip.gap");
}

#[test]
fn a_zip_entry_and_a_folder_of_the_same_name_collide() {
    let mut z = Fx::minimal().zip_entries();
    z.push(ZE::dir("payload/game"));
    assert_rejected(check_zip(write_zip(&z)), "zip.duplicate_entry");
}

#[test]
fn table_kinds_must_match_the_package() {
    // A directory in the table that is a file in the package, and a file that is a folder.
    let mut with_dir = Fx::minimal();
    with_dir.dirs.push("payload/sub".into());
    let mut m = Fx::minimal();
    m.table_override = Some(with_dir.table());
    let mut src = m.mem();
    assert_rejected(
        validate(&src, &ValidateOptions::default()),
        "package.missing_dir",
    );
    src.add_file("payload/sub", b"x".to_vec());
    assert_rejected(
        validate(&src, &ValidateOptions::default()),
        "package.kind_mismatch",
    );

    // `payload/game` is a file in the table; present it as a folder.
    let fx = Fx::minimal();
    let mut src = ruya_play_format::MemorySource::new();
    src.add_file("play.json", fx.manifest_bytes());
    src.add_file("play.files", fx.table());
    src.add_file("art/icon.png", fx.files[0].1.clone());
    src.add_dir("payload/game");
    assert_rejected_at(
        validate(&src, &ValidateOptions::default()),
        "package.kind_mismatch",
        "payload/game",
    );
}
