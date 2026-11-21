//! Round 2 of RUY-92: duplicate JSON keys, ZIP64 overflow, content never read for a bad name, a
//! newer format first, package text in problems, and the smaller rules the reviews asked for.

mod common;

use common::*;
use ruya_play_format::{validate, EntryKind, MemorySource, Problem, Source, ValidateOptions};
use serde_json::json;
use std::cell::RefCell;
use std::io::{self, Read};

// ----- duplicate keys ----------------------------------------------------------------------------

fn raw_manifest(fx: &Fx, edit: impl Fn(String) -> String) -> Fx {
    let mut fx = fx.clone();
    fx.manifest_override = Some(edit(serde_json::to_string(&fx.manifest).unwrap()).into_bytes());
    fx
}

#[test]
fn json_duplicate_key_at_the_top_level() {
    let fx = raw_manifest(&Fx::minimal(), |t| format!("{{\"build\":2,{}", &t[1..]));
    assert_rejected_at(check(&fx), "json.duplicate_key", "");
}

#[test]
fn json_duplicate_key_nested_and_after_decoding_escapes() {
    let fx = raw_manifest(&Fx::minimal(), |t| {
        t.replace("\"run\":{", "\"run\":{\"runner\":\"wine\",")
    });
    assert_rejected_at(check(&fx), "json.duplicate_key", "/run");
    // "\u0062uild" is "build".
    let fx = raw_manifest(&Fx::minimal(), |t| {
        format!("{{\"\\u0062uild\":2,{}", &t[1..])
    });
    assert_rejected_at(check(&fx), "json.duplicate_key", "");
    // A surrogate pair decodes to one character, so these two keys are the same key.
    let fx = raw_manifest(&Fx::minimal(), |t| {
        format!("{{\"x\\ud83d\\ude00\":1,\"x\u{1F600}\":2,{}", &t[1..])
    });
    assert_rejected_at(check(&fx), "json.duplicate_key", "");
    // Inside an array.
    let fx = raw_manifest(&Fx::minimal(), |t| {
        format!("{{\"tags\":[{{\"a\":1,\"a\":2}}],{}", &t[1..])
    });
    assert_rejected_at(check(&fx), "json.duplicate_key", "/tags/0");
}

#[test]
fn the_same_key_in_two_different_objects_is_fine() {
    let fx = raw_manifest(&Fx::minimal(), |t| {
        format!("{{\"x\":{{\"a\":1}},\"y\":{{\"a\":2}},{}", &t[1..])
    });
    assert_valid(check(&fx));
}

#[test]
fn a_duplicate_key_in_a_table_line_is_a_bad_line() {
    let mut fx = Fx::minimal();
    fx.table_override = Some(b"{\"p\":\"a\",\"p\":\"b\",\"t\":\"d\"}\n".to_vec());
    assert_rejected(check(&fx), "table.line_invalid");
    fx.table_override = Some(b"{\"p\":\"a\",\"t\":\"d\",\"x\":1,\"x\":1}\n".to_vec());
    assert_rejected(check(&fx), "table.line_invalid");
}

// ----- ZIP64 arithmetic --------------------------------------------------------------------------

#[test]
fn zip64_record_size_that_overflows_is_refused_not_a_panic() {
    // 98 bytes: a ZIP64 end record claiming a size near u64::MAX, its locator, the end record.
    let mut z: Vec<u8> = Vec::new();
    z.extend(0x0606_4b50u32.to_le_bytes());
    z.extend((u64::MAX - 4).to_le_bytes()); // size of the rest: 0 + 12 + this overflows
    z.extend([0u8; 44]);
    assert_eq!(z.len(), 56);
    z.extend(0x0706_4b50u32.to_le_bytes());
    z.extend(0u32.to_le_bytes());
    z.extend(0u64.to_le_bytes()); // record at offset 0
    z.extend(1u32.to_le_bytes());
    z.extend(0x0605_4b50u32.to_le_bytes());
    z.extend([0u8; 4]);
    z.extend(0xFFFFu16.to_le_bytes());
    z.extend(0xFFFFu16.to_le_bytes());
    z.extend(0xFFFF_FFFFu32.to_le_bytes());
    z.extend(0xFFFF_FFFFu32.to_le_bytes());
    z.extend(0u16.to_le_bytes());
    assert_eq!(z.len(), 98);
    assert_rejected(check_zip(z), "zip.malformed");
}

#[test]
fn a_declared_size_of_u64_max_does_not_overflow_while_reading() {
    // Declared sizes come from the file; nothing computed from them may wrap.
    let mut z = Fx::minimal().zip_entries();
    z[2].declared_usize = Some(u64::MAX);
    assert!(check_zip(write_zip(&z)).is_err());
}

#[test]
fn a_second_zip64_extra_field_is_refused() {
    let mut z = Fx::minimal().zip_entries();
    z[2].cd_extra = [
        1u16.to_le_bytes(),
        0u16.to_le_bytes(),
        1u16.to_le_bytes(),
        0u16.to_le_bytes(),
    ]
    .concat();
    assert_rejected(check_zip(write_zip(&z)), "zip.malformed");
    // One is fine.
    let mut z = Fx::minimal().zip_entries();
    z[2].cd_extra = [1u16.to_le_bytes(), 0u16.to_le_bytes()].concat();
    assert_valid(check_zip(write_zip(&z)));
}

#[test]
fn a_data_descriptor_must_agree_with_the_directory() {
    let mut z = Fx::minimal().zip_entries();
    for e in z.iter_mut() {
        e.flags |= 8;
    }
    z[2].descriptor_crc = Some(0xDEAD_BEEF);
    assert_rejected(check_zip(write_zip(&z)), "zip.local_mismatch");
}

#[test]
fn the_unwrapped_top_folder_is_path_checked() {
    let z: Vec<ZE> = Fx::minimal()
        .zip_entries()
        .into_iter()
        .map(|mut e| {
            e.name = format!("../{}", e.name);
            e.local_name = Some(e.name.clone());
            e
        })
        .collect();
    // Every name starts with "../": the folder must not be dropped to hide the traversal.
    assert_rejected(check_zip(write_zip(&z)), "path.traversal");
}

// ----- nothing is read for a bad name -------------------------------------------------------------

struct Recording {
    inner: MemorySource,
    opened: RefCell<Vec<String>>,
}

impl Source for Recording {
    fn entries(&self) -> Result<Vec<ruya_play_format::Entry>, Vec<Problem>> {
        self.inner.entries()
    }
    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        self.opened.borrow_mut().push(path.to_string());
        self.inner.open(path)
    }
}

/// The manifest is read first (for its `format`); no other file may be opened when a name or a
/// kind is wrong.
#[track_caller]
fn assert_only_the_manifest_is_read(inner: MemorySource, code: &str) {
    let src = Recording {
        inner,
        opened: RefCell::new(vec![]),
    };
    let r = validate(&src, &ValidateOptions::default());
    assert_rejected(r, code);
    let opened = src.opened.borrow();
    assert!(opened.iter().all(|p| p == "play.json"), "opened {opened:?}");
}

#[test]
fn nothing_but_the_manifest_is_opened_for_a_path_fault() {
    let mut m = Fx::minimal().mem();
    m.add_file("payload/../x", b"x".to_vec());
    assert_only_the_manifest_is_read(m, "path.traversal");
}

#[test]
fn nothing_but_the_manifest_is_opened_for_a_kind_fault() {
    let mut m = Fx::minimal().mem();
    m.add_entry("payload/link", EntryKind::Symlink);
    assert_only_the_manifest_is_read(m, "entry.symlink");
}

#[test]
fn a_clean_package_does_open_its_files() {
    // The recording works: a valid package is read.
    let src = Recording {
        inner: Fx::minimal().mem(),
        opened: RefCell::new(vec![]),
    };
    assert_valid(validate(&src, &ValidateOptions::default()));
    assert!(src.opened.borrow().iter().any(|p| p == "payload/game"));
}

// ----- a newer format first -----------------------------------------------------------------------

fn future(format_json: &str) -> Fx {
    let mut fx = Fx::minimal();
    // The table breaks v1 rules and a name is bad: none of it may be reported.
    fx.table_override = Some(b"not a table\n".to_vec());
    fx.file("payload/../evil", b"x");
    fx.manifest_override =
        Some(format!("{{\"format\": {format_json}, \"run\": 12, \"id\": false}}").into_bytes());
    fx
}

#[test]
fn format_too_new_is_the_only_answer_for_a_newer_package() {
    for f in [
        "2",
        "2.0",
        "3",
        "1000000",
        "1e20",
        "18446744073709551616",
        "2.5",
    ] {
        let r = check(&future(f));
        let Err(p) = r else { panic!("{f} accepted") };
        assert_eq!(
            p.iter().map(|x| x.code.as_str()).collect::<Vec<_>>(),
            ["format.too_new"],
            "{f}"
        );
    }
}

#[test]
fn format_too_new_also_for_a_zip() {
    let fx = future("2");
    let r = check_zip(fx.zip());
    let Err(p) = r else { panic!("accepted") };
    assert_eq!(p.len(), 1);
    assert_eq!(p[0].code, "format.too_new");
}

#[test]
fn format_that_is_not_a_number_of_one_or_more_is_invalid() {
    for f in ["0", "-1", "1.5", "1.0", "\"2\"", "true", "null", "[2]"] {
        let mut fx = Fx::minimal();
        fx.manifest["format"] = serde_json::from_str(f).unwrap();
        assert_rejected(check(&fx), "format.invalid");
    }
}

// ----- package text in problems -------------------------------------------------------------------

#[test]
fn package_text_in_problems_is_escaped_and_clipped() {
    let mut fx = Fx::minimal();
    fx.manifest["permissions"] = json!({ "k".repeat(500_000): true });
    let Err(p) = check(&fx) else {
        panic!("accepted")
    };
    assert!(!p.is_empty());
    for x in &p {
        assert!(x.path.chars().count() <= 170, "path {}", x.path.len());
        assert!(
            x.message.chars().count() <= 620,
            "message {}",
            x.message.len()
        );
    }
    assert!(p.iter().any(|x| x.code == "permissions.unknown_key"));
}

#[test]
fn an_env_name_with_a_right_to_left_override_is_shown_escaped() {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["env"] = json!({ "A\u{202E}B\u{200B}": "1", "bad\nname": "2" });
    let Err(p) = check(&fx) else {
        panic!("accepted")
    };
    assert!(p.iter().filter(|x| x.code == "env.bad_name").count() >= 2);
    for x in &p {
        for field in [&x.path, &x.message] {
            assert!(
                !field
                    .chars()
                    .any(|c| matches!(c, '\u{202E}' | '\u{200B}' | '\n')),
                "{x:?}"
            );
        }
    }
    assert!(
        p.iter()
            .any(|x| x.path.contains("\\u{202E}") && x.message.contains("\\u{202E}")),
        "{p:?}"
    );
}

#[test]
fn quote_escapes_and_clips() {
    use ruya_play_format::problem::{quote, safe_text};
    assert_eq!(quote("a\"b\\c"), "\"a\\\"b\\\\c\"");
    assert_eq!(quote("x\u{202E}y"), "\"x\\u{202E}y\"");
    assert_eq!(quote(&"z".repeat(80)), format!("\"{}\"", "z".repeat(80)));
    assert_eq!(quote(&"z".repeat(81)), format!("\"{}...\"", "z".repeat(80)));
    assert_eq!(safe_text("a\u{0}b", 10), "a\\u{0000}b");
}

#[test]
fn a_path_with_odd_characters_is_escaped_in_problems() {
    let mut m = Fx::minimal().mem();
    m.add_file("payload/ev\u{202E}il.exe", b"x".to_vec());
    let Err(p) = validate(&m, &ValidateOptions::default()) else {
        panic!("accepted")
    };
    assert!(
        p.iter()
            .all(|x| !x.path.contains('\u{202E}') && !x.message.contains('\u{202E}')),
        "{p:?}"
    );
}

// ----- the smaller rules --------------------------------------------------------------------------

fn with_env(name: &str) -> Fx {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["env"] = json!({ name: "x" });
    fx
}

#[test]
fn more_names_the_platform_owns() {
    for name in [
        "WINEARCH",
        "TMPDIR",
        "GCONV_PATH",
        "LOCPATH",
        "NLSPATH",
        "PWD",
        "UMU_ID",
        "PRESSURE_VESSEL_FILESYSTEMS_RW",
    ] {
        assert_rejected_at(
            check(&with_env(name)),
            "env.reserved",
            &format!("/run/env/{name}"),
        );
    }
    // Close neighbours stay allowed.
    for name in [
        "WINEDEBUG",
        "TMPDIR_HINT",
        "LOCPATHS",
        "PWD_HINT",
        "UMU_ID2",
    ] {
        assert_valid(check(&with_env(name)));
    }
}

#[test]
fn reserved_id_prefixes_ignore_case() {
    for id in [
        "ORG.RuyaOS.settings",
        "Org.ruyaos.x",
        "PLAY.com.example",
        "Play.Com.Example",
    ] {
        let mut fx = Fx::minimal();
        fx.manifest["id"] = json!(id);
        assert_rejected(check(&fx), "id.reserved");
    }
    let mut fx = Fx::minimal();
    fx.manifest["id"] = json!("ORG.RuyaOS.settings");
    let opts = ValidateOptions {
        official: true,
        ..Default::default()
    };
    assert_valid(validate(&fx.mem(), &opts));
}

#[test]
fn language_tags_that_differ_only_in_case_are_one_tag() {
    let mut fx = Fx::minimal();
    fx.manifest["name"] = json!({"en": "A", "EN": "B"});
    assert_rejected(check(&fx), "list.duplicate");
    let mut fx = Fx::minimal();
    fx.manifest["summary"] = json!({"en": "A", "pt-BR": "B", "pt-br": "C"});
    assert_rejected(check(&fx), "list.duplicate");
    let mut fx = Fx::wine_full();
    fx.manifest["art"]["logo"] = json!({"de": "art/logo.webp", "DE": "art/logo.webp"});
    assert_rejected(check(&fx), "list.duplicate");
}

#[test]
fn dot_dot_in_arguments_that_start_with_a_placeholder() {
    let mut fx = Fx::minimal();
    fx.manifest["run"]["command"] = json!(["${payload}/game", "${payload}/../../etc/passwd"]);
    assert_rejected_at(check(&fx), "run.argument_path", "/run/command/1");
    fx.manifest["run"]["command"] = json!(["${payload}/game", "${data}/a/../b"]);
    assert_rejected(check(&fx), "run.argument_path");
    // A plain argument is the game's business; so is a name that only contains two dots.
    fx.manifest["run"]["command"] =
        json!(["${payload}/game", "../x", "${data}/a..b", "--level=1..3"]);
    assert_valid(check(&fx));
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["setup"][0]["command"] =
        json!(["${payload}/redist/vc_redist.x64.exe", "${config}/../x"]);
    assert_rejected(check(&fx), "run.argument_path");
}

#[test]
fn prefix_template_and_bundled_path_must_be_folders() {
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["prefix"]["template"] = json!("components/wine/lib/libwine.so");
    assert_rejected(check(&fx), "prefix.template_missing");
    let mut fx = Fx::wine_full();
    fx.manifest["run"]["prefix"]["template"] = json!("payload/StarHopper.exe");
    assert_rejected(check(&fx), "prefix.template_missing");
    let mut fx = Fx::wine_full();
    fx.manifest["components"][0]["bundled"]["path"] = json!("components/wine/lib/libwine.so");
    assert_rejected(check(&fx), "component.bundled_missing");
}
