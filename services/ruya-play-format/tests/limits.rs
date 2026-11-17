//! Every named limit has a boundary test: one below, at, and one above (05 §9.3 rule 6).

mod common;

use common::*;
use ruya_play_format::limits::*;
use ruya_play_format::{validate, ValidateOptions, ZipSource};
use serde_json::{json, Value};
use std::io::Cursor;

/// `limit - 1` and `limit` are accepted; `limit + 1` is rejected with `code`.
#[track_caller]
fn bound(limit: usize, code: &str, make: impl Fn(usize) -> Fx) {
    assert_valid(check(&make(limit - 1)));
    assert_valid(check(&make(limit)));
    assert_rejected(check(&make(limit + 1)), code);
}

fn a(n: usize) -> String {
    "a".repeat(n)
}

fn set(key: &str, v: Value) -> Fx {
    let mut fx = Fx::minimal();
    fx.manifest[key] = v;
    fx
}

// ----- sizes and shapes of the metadata files ------------------------------------------------

#[test]
fn manifest_bytes() {
    bound(MAX_MANIFEST_BYTES as usize, "manifest.too_big", |n| {
        let mut fx = Fx::minimal();
        let text = serde_json::to_string(&fx.manifest).unwrap();
        fx.manifest_override = Some(format!("{text}{}", " ".repeat(n - text.len())).into_bytes());
        fx
    });
}

#[test]
fn json_depth() {
    bound(MAX_JSON_DEPTH, "manifest.too_deep", |depth| {
        let mut fx = Fx::minimal();
        let mut v = json!("x");
        for _ in 0..depth - 1 {
            v = json!([v]);
        }
        fx.manifest["extra"] = v;
        fx
    });
}

#[test]
fn json_depth_ignores_brackets_inside_strings() {
    let mut fx = Fx::minimal();
    fx.manifest["extra"] = json!("[[[[[[[[[[[[[[[[[[[[ \" [[[[[[[[[[[[[[[[[[[[[[[[");
    assert_valid(check(&fx));
}

#[test]
fn table_bytes() {
    bound(MAX_TABLE_BYTES as usize, "table.too_big", |n| {
        let mut fx = Fx::minimal();
        let mut t = fx.table();
        let pad = n - t.len();
        // JSON allows whitespace after the last value of a line.
        t.truncate(t.len() - 1);
        t.extend(std::iter::repeat_n(b' ', pad));
        t.push(b'\n');
        fx.table_override = Some(t);
        fx
    });
}

fn many_files(total_entries: usize) -> Fx {
    let mut fx = Fx::minimal();
    for i in 0..total_entries - 2 {
        fx.files.push((format!("payload/f{i:06}"), vec![]));
    }
    fx
}

#[test]
fn table_entries() {
    // Content is not read: the count is a property of the table, and 200,000 reads are slow in a debug build.
    let opts = ValidateOptions {
        verify_content: false,
        ..Default::default()
    };
    for n in [MAX_TABLE_ENTRIES - 1, MAX_TABLE_ENTRIES] {
        assert_valid(validate(&many_files(n).mem(), &opts));
    }
    assert_rejected(
        validate(&many_files(MAX_TABLE_ENTRIES + 1).mem(), &opts),
        "table.too_many",
    );
}

// ----- paths ---------------------------------------------------------------------------------

fn path_of_len(prefix: &str, n: usize) -> String {
    let mut p = prefix.to_string();
    let mut room = n - p.len();
    while room > 0 {
        let take = room.min(200);
        p.push_str(&a(take));
        room -= take;
        if room > 0 {
            p.push('/');
            room -= 1;
        }
    }
    assert_eq!(p.len(), n);
    p
}

#[test]
fn path_bytes() {
    bound(MAX_PATH_BYTES, "path.too_long", |n| {
        let mut fx = Fx::minimal();
        fx.file(&path_of_len("payload/", n), b"x");
        fx
    });
}

#[test]
fn component_bytes() {
    bound(MAX_COMPONENT_BYTES, "path.component_too_long", |n| {
        let mut fx = Fx::minimal();
        fx.file(&format!("payload/{}", a(n)), b"x");
        fx
    });
}

#[test]
fn link_hops() {
    bound(MAX_LINK_HOPS, "link.chain_too_long", |hops| {
        let mut fx = Fx::minimal();
        fx.file("payload/lib/real.so", b"so");
        for i in 1..=hops {
            let to = if i == hops {
                "real.so".to_string()
            } else {
                format!("l{}", i + 1)
            };
            fx.links.push((format!("payload/lib/l{i}"), to));
        }
        fx
    });
}

// ----- zip -----------------------------------------------------------------------------------

#[test]
fn expansion_ratio_arithmetic() {
    assert!(
        !expansion_exceeds(EXPANSION_FREE_BYTES, 0),
        "an entry of 1 MiB is exempt"
    );
    assert!(expansion_exceeds(EXPANSION_FREE_BYTES + 1, 0));
    let c = 6000;
    assert!(
        !expansion_exceeds(MAX_EXPANSION_RATIO * c, c),
        "exactly 200:1 is allowed"
    );
    assert!(
        expansion_exceeds(MAX_EXPANSION_RATIO * c + 1, c),
        "more than 200:1 is not"
    );
    assert!(!expansion_exceeds(MAX_EXPANSION_RATIO * c - 1, c));
}

fn zip_with_declared_ratio(usize_: u64, csize: u64) -> Vec<u8> {
    let mut z = Fx::minimal().zip_entries();
    let mut e = ZE::file("payload/big.bin", vec![]).deflated();
    e.declared_usize = Some(usize_);
    e.declared_csize = Some(csize);
    e.precompressed = Some(vec![0u8; csize as usize]);
    z.push(e);
    write_zip(&z)
}

#[test]
fn expansion_ratio_in_a_zip() {
    let c = 6000u64;
    // At the limit and one below: the listing is accepted (the content is junk, but never read here).
    for u in [MAX_EXPANSION_RATIO * c - 1, MAX_EXPANSION_RATIO * c] {
        assert!(
            ZipSource::new(Cursor::new(zip_with_declared_ratio(u, c))).is_ok(),
            "{u}"
        );
    }
    let r = ZipSource::new(Cursor::new(zip_with_declared_ratio(
        MAX_EXPANSION_RATIO * c + 1,
        c,
    )));
    assert!(r.err().unwrap().iter().any(|p| p.code == "zip.ratio"));
    // Small entries are exempt however well they compress.
    let ok = zip_with_declared_ratio(EXPANSION_FREE_BYTES, 10);
    assert!(ZipSource::new(Cursor::new(ok)).is_ok());
    let r = ZipSource::new(Cursor::new(zip_with_declared_ratio(
        EXPANSION_FREE_BYTES + 1,
        10,
    )));
    assert!(r.err().unwrap().iter().any(|p| p.code == "zip.ratio"));
}

#[test]
fn zip_entries_and_zip64() {
    let entries =
        |n: usize| -> Vec<ZE> { (0..n).map(|i| ZE::file(&format!("f{i}"), vec![])).collect() };
    for n in [MAX_ZIP_ENTRIES - 1, MAX_ZIP_ENTRIES] {
        let z = write_zip_opts(&entries(n), true);
        let src = ZipSource::new(Cursor::new(z)).unwrap_or_else(|p| panic!("{n}: {p:?}"));
        use ruya_play_format::Source;
        assert_eq!(src.entries().unwrap().len(), n);
    }
    let z = write_zip_opts(&entries(MAX_ZIP_ENTRIES + 1), true);
    let r = ZipSource::new(Cursor::new(z));
    assert!(r
        .err()
        .unwrap()
        .iter()
        .any(|p| p.code == "zip.too_many_entries"));
}

#[test]
fn zip64_end_records_are_read() {
    let z = write_zip_opts(&Fx::wine_full().zip_entries(), true);
    assert_valid(check_zip(z));
}

// ----- text and lists in play.json -----------------------------------------------------------

#[test]
fn languages() {
    bound(MAX_LANGUAGES, "lang.too_many", |n| {
        let mut m = serde_json::Map::new();
        m.insert("en".into(), json!("Mini"));
        let letters: Vec<char> = ('a'..='z').collect();
        'outer: for x in &letters {
            for y in &letters {
                if m.len() == n {
                    break 'outer;
                }
                let tag = format!("{x}{y}");
                if tag != "en" {
                    m.insert(tag, json!("Mini"));
                }
            }
        }
        set("name", Value::Object(m))
    });
}

#[test]
fn name_summary_description_version_chars() {
    bound(MAX_NAME_CHARS, "text.too_long", |n| {
        set("name", json!({"en": a(n)}))
    });
    bound(MAX_SUMMARY_CHARS, "text.too_long", |n| {
        set("summary", json!({"en": a(n)}))
    });
    bound(MAX_DESCRIPTION_CHARS, "text.too_long", |n| {
        set("description", json!({"en": a(n)}))
    });
    bound(MAX_VERSION_CHARS, "text.too_long", |n| {
        set("version", json!(a(n)))
    });
}

#[test]
fn characters_are_counted_not_bytes() {
    // 60 two-byte characters are 120 bytes and still a legal name.
    assert_valid(check(&set(
        "name",
        json!({"en": "\u{e9}".repeat(MAX_NAME_CHARS)}),
    )));
    assert_rejected(
        check(&set(
            "name",
            json!({"en": "\u{e9}".repeat(MAX_NAME_CHARS + 1)}),
        )),
        "text.too_long",
    );
}

#[test]
fn credit_names() {
    bound(MAX_CREDIT_NAME_CHARS, "text.too_long", |n| {
        set("developer", json!({"name": a(n)}))
    });
    bound(MAX_CREDIT_NAME_CHARS, "text.too_long", |n| {
        set("publisher", json!({"name": a(n)}))
    });
}

#[test]
fn genres_tags_links() {
    bound(MAX_GENRES, "list.too_long", |n| {
        set("genres", json!(GENRES.iter().take(n).collect::<Vec<_>>()))
    });
    bound(MAX_TAGS, "list.too_long", |n| {
        set(
            "tags",
            json!((0..n).map(|i| format!("t{i}")).collect::<Vec<_>>()),
        )
    });
    bound(MAX_TAG_CHARS, "text.too_long", |n| {
        set("tags", json!([a(n)]))
    });
    bound(MAX_LINKS, "list.too_long", |n| {
        set(
            "links",
            json!((0..n)
                .map(|i| json!({"kind": "other", "url": format!("https://example.com/{i}")}))
                .collect::<Vec<_>>()),
        )
    });
    bound(MAX_URL_BYTES, "url.invalid", |n| {
        let url = format!(
            "https://example.com/{}",
            a(n - "https://example.com/".len())
        );
        set("links", json!([{"kind": "homepage", "url": url}]))
    });
}

#[test]
fn players_age_licence() {
    bound(MAX_PLAYERS as usize, "value.range", |n| {
        set("players", json!({"min": 1, "max": n}))
    });
    bound(MAX_AGE_ATTRIBUTES, "list.too_long", |n| {
        let content: serde_json::Map<String, Value> = (0..n)
            .map(|i| (format!("attr-{i}"), json!("mild")))
            .collect();
        set(
            "age_rating",
            json!({"scheme": "oars-1.1", "content": content}),
        )
    });
    bound(MAX_LICENCE_BYTES, "value.unknown", |n| {
        set("licence", json!({"package": a(n)}))
    });
}

#[test]
fn screenshots_and_captions() {
    bound(MAX_SCREENSHOTS, "list.too_long", |n| {
        let mut fx = Fx::minimal();
        let mut shots = vec![];
        for i in 0..n {
            fx.file(&format!("art/s{i}.png"), b"s");
            shots.push(json!({"file": format!("art/s{i}.png")}));
        }
        fx.manifest["art"]["screenshots"] = json!(shots);
        fx
    });
    bound(MAX_CAPTION_CHARS, "text.too_long", |n| {
        let mut fx = Fx::minimal();
        fx.file("art/s.png", b"s");
        fx.manifest["art"]["screenshots"] = json!([{"file": "art/s.png", "caption": {"en": a(n)}}]);
        fx
    });
}

#[test]
fn reasons() {
    bound(MAX_REASON_CHARS, "text.too_long", |n| {
        set(
            "permissions",
            json!({"network": true, "reasons": {"network": {"en": a(n)}}}),
        )
    });
}

#[test]
fn ids() {
    bound(MAX_ID_BYTES, "id.invalid", |n| {
        set(
            "id",
            json!(format!("com.example.{}", a(n - "com.example.".len()))),
        )
    });
    // `play.<id>` cannot pass 255 bytes while `id` is held to 120: the Flatpak length check is a
    // second line of defence and has no boundary of its own to test.
    assert!(MAX_FLATPAK_ID_BYTES > MAX_ID_BYTES + "play.".len());
}

// ----- run and components --------------------------------------------------------------------

fn run_set(key: &str, v: Value) -> Fx {
    let mut fx = Fx::minimal();
    fx.manifest["run"][key] = v;
    fx
}

#[test]
fn env_limits() {
    bound(MAX_ENV_ENTRIES, "list.too_long", |n| {
        let env: serde_json::Map<String, Value> =
            (0..n).map(|i| (format!("VAR_{i}"), json!("1"))).collect();
        run_set("env", Value::Object(env))
    });
    bound(MAX_ENV_VALUE_BYTES, "env.bad_value", |n| {
        run_set("env", json!({"VAR": a(n)}))
    });
    bound(MAX_ENV_NAME_BYTES, "env.bad_name", |n| {
        run_set("env", json!({ format!("V{}", "A".repeat(n - 1)): "1" }))
    });
}

#[test]
fn command_limits() {
    bound(MAX_COMMAND_ARGS, "list.too_long", |n| {
        let mut cmd = vec!["${payload}/game".to_string()];
        cmd.extend((1..n).map(|i| format!("a{i}")));
        run_set("command", json!(cmd))
    });
    bound(MAX_ARG_BYTES, "text.too_long", |n| {
        run_set("command", json!(["${payload}/game", a(n)]))
    });
}

#[test]
fn setup_discs_and_data_paths() {
    bound(MAX_SETUP_STEPS, "list.too_long", |n| {
        let steps: Vec<Value> = (0..n)
            .map(|i| json!({"id": format!("s{i}"), "command": ["${payload}/game"]}))
            .collect();
        run_set("setup", json!(steps))
    });
    bound(MAX_DISCS, "list.too_long", |n| {
        let mut fx = Fx::minimal();
        let mut discs = vec![];
        for i in 0..n {
            fx.file(&format!("payload/d{i}.iso"), b"d");
            discs.push(format!("payload/d{i}.iso"));
        }
        fx.manifest["run"]["discs"] = json!(discs);
        fx
    });
    bound(MAX_DATA_PATHS, "list.too_long", |n| {
        set(
            "data",
            json!({"saves": (0..n).map(|i| format!("data:s{i}")).collect::<Vec<_>>()}),
        )
    });
    bound(MAX_DATA_PATHS, "list.too_long", |n| {
        set(
            "data",
            json!({"cache": (0..n).map(|i| format!("data:c{i}")).collect::<Vec<_>>()}),
        )
    });
}

#[test]
fn components_and_their_ids() {
    bound(MAX_COMPONENTS, "list.too_long", |n| {
        let comps: Vec<Value> = (0..n).map(|i| json!({"id": format!("c{i}"), "type": "wine", "source": "system", "min": "9.0"})).collect();
        set("components", json!(comps))
    });
    bound(MAX_LOCAL_ID_BYTES, "value.unknown", |n| {
        set(
            "components",
            json!([{"id": a(n), "type": "wine", "source": "system", "min": "9.0"}]),
        )
    });
    bound(MAX_COMPONENT_VERSION_BYTES, "value.unknown", |n| {
        set(
            "components",
            json!([{"id": "w", "type": "wine", "source": "system", "min": "9".repeat(n)}]),
        )
    });
}

// ----- the problem list itself ---------------------------------------------------------------

#[test]
fn problems_are_capped_and_say_so() {
    let mut fx = Fx::minimal();
    for i in 0..(MAX_PROBLEMS + 50) {
        fx.file(&format!("payload/bad\\{i}"), b"x");
    }
    let Err(p) = validate(&fx.mem(), &ValidateOptions::default()) else {
        panic!("accepted")
    };
    assert_eq!(p.len(), MAX_PROBLEMS + 1);
    assert_eq!(p.last().unwrap().code, "problems.truncated");
}

// ----- the values of the spec, written out ---------------------------------------------------

#[test]
fn the_constants_are_the_numbers_of_the_spec() {
    // docs/specs/05-play-packages.md 4.4. A boundary test above moves with its constant, so the
    // numbers themselves are pinned here.
    assert_eq!(MAX_MANIFEST_BYTES, 1024 * 1024);
    assert_eq!(MAX_JSON_DEPTH, 12);
    assert_eq!(MAX_TABLE_BYTES, 64 * 1024 * 1024);
    assert_eq!(MAX_TABLE_ENTRIES, 200_000);
    assert_eq!(MAX_ZIP_ENTRIES, 220_000);
    assert_eq!((MAX_PATH_BYTES, MAX_COMPONENT_BYTES), (1024, 255));
    assert_eq!(MAX_LINK_HOPS, 8);
    assert_eq!(
        (EXPANSION_FREE_BYTES, MAX_EXPANSION_RATIO),
        (1024 * 1024, 200)
    );
    assert_eq!(MAX_LANGUAGES, 30);
    assert_eq!(
        (
            MAX_NAME_CHARS,
            MAX_SUMMARY_CHARS,
            MAX_DESCRIPTION_CHARS,
            MAX_VERSION_CHARS
        ),
        (60, 140, 4000, 32)
    );
    assert_eq!(
        (MAX_CREDIT_NAME_CHARS, MAX_TAG_CHARS, MAX_TAGS, MAX_GENRES),
        (80, 24, 12, 4)
    );
    assert_eq!((MAX_LINKS, MAX_URL_BYTES), (12, 2048));
    assert_eq!(
        (MAX_SCREENSHOTS, MAX_CAPTION_CHARS, MAX_REASON_CHARS),
        (20, 100, 120)
    );
    assert_eq!(
        (MAX_ID_BYTES, MAX_FLATPAK_ID_BYTES, MIN_ID_ELEMENTS),
        (120, 255, 3)
    );
    assert_eq!(
        (
            MAX_COMPONENTS,
            MAX_LOCAL_ID_BYTES,
            MAX_COMPONENT_VERSION_BYTES
        ),
        (16, 32, 32)
    );
    assert_eq!(
        (MAX_ENV_ENTRIES, MAX_ENV_NAME_BYTES, MAX_ENV_VALUE_BYTES),
        (64, 64, 1024)
    );
    assert_eq!((MAX_COMMAND_ARGS, MAX_ARG_BYTES), (64, 4096));
    assert_eq!((MAX_SETUP_STEPS, MAX_DISCS, MAX_DATA_PATHS), (16, 16, 32));
    assert_eq!(
        (MAX_PLAYERS, MAX_AGE_ATTRIBUTES, MAX_LICENCE_BYTES),
        (64, 40, 128)
    );
    assert_eq!(MAX_PROBLEMS, 100);
    assert_eq!(SUPPORTED_FORMAT, 1);
}
