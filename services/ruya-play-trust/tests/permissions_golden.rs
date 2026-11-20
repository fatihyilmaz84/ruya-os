//! ADR-038 (RUY-909): a generation bump never widens a grant. The golden
//! (`tests/golden/permission-grants.txt`) lists what each word of 05 §8 granted when it was
//! adopted; a row of `PERMISSIONS` that grants more fails here. The parser the re-commit uses
//! reads what `metadata_sections` writes, and `widened` finds what a new set adds.

use ruya_play_trust::permissions::{display_socket, ALWAYS};
use ruya_play_trust::{
    added_to, metadata_sections, parse_sections, widened, Grant, Granted, Section, PERMISSIONS,
};

/// One grant of the golden: `[Section] key=value`.
fn granted(text: &str) -> Granted {
    let (section, rest) = text.strip_prefix('[').unwrap().split_once("] ").unwrap();
    let (key, value) = rest.split_once('=').unwrap();
    Granted {
        section: [Section::Context, Section::SessionBusPolicy]
            .into_iter()
            .find(|s| s.name() == section)
            .unwrap_or_else(|| panic!("section of {text}")),
        key: key.to_string(),
        value: value.to_string(),
    }
}

/// The golden: each word (`key=value`, or `(always)`) with the grants it listed.
fn golden() -> Vec<(String, Vec<Granted>)> {
    let text = include_str!("golden/permission-grants.txt");
    text.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .map(|l| {
            let (word, rest) = l.split_once(" =>").unwrap_or_else(|| panic!("{l}"));
            let grants = rest
                .split('|')
                .map(str::trim)
                .filter(|g| !g.is_empty())
                .map(granted)
                .collect();
            (word.to_string(), grants)
        })
        .collect()
}

/// What `new` adds to a deployed `metadata` text that reads safely.
fn added(deployed: &str, new: &[Grant]) -> Vec<String> {
    widened(deployed, new).expect("the metadata reads")
}

fn listed(word: &str) -> Vec<Granted> {
    golden()
        .into_iter()
        .find(|(w, _)| w == word)
        .unwrap_or_else(|| panic!("{word} is not in the golden"))
        .1
}

#[test]
fn no_row_grants_more_than_its_golden() {
    let golden = golden();
    for row in &PERMISSIONS {
        let word = format!("{}={}", row.key, row.value);
        // A new word is not in the golden and passes.
        let Some((_, have)) = golden.iter().find(|(w, _)| *w == word) else {
            continue;
        };
        let added = added_to(have, row.grants);
        assert!(
            added.is_empty(),
            "{word} now grants {added:?} beyond its golden: a broader grant is a new vocabulary \
             word, not a change of a row (ADR-038). Narrowing a row updates its golden line."
        );
    }
}

#[test]
fn the_row_every_app_gets_stays_within_its_golden() {
    let mut now: Vec<Grant> = ALWAYS.to_vec();
    for runner in ["native", "wine"] {
        now.push(display_socket(runner));
    }
    assert_eq!(added_to(&listed("(always)"), &now), Vec::<String>::new());
    // The golden itself catches a gain: another socket for everyone.
    now.push(Grant {
        section: Section::Context,
        key: "sockets",
        value: "ssh-auth",
    });
    assert_eq!(added_to(&listed("(always)"), &now).len(), 1);
}

#[test]
fn a_narrowed_row_passes_its_golden() {
    let have = listed("removable_media=write");
    let narrowed = [Grant {
        section: Section::Context,
        key: "filesystems",
        value: "/run/media:ro",
    }];
    assert!(added_to(&have, &narrowed).is_empty());
    assert!(added_to(&have, &[]).is_empty());
    // And a gain is found: the read-only row asking for read-write.
    let wider = [Grant {
        section: Section::Context,
        key: "filesystems",
        value: "/run/media",
    }];
    assert_eq!(added_to(&listed("removable_media=read"), &wider).len(), 1);
}

#[test]
fn the_parser_reads_what_metadata_sections_writes() {
    let mut all: Vec<Grant> = ALWAYS.to_vec();
    all.push(display_socket("wine"));
    for row in &PERMISSIONS {
        for g in row.grants {
            if !all.contains(g) {
                all.push(*g);
            }
        }
    }
    let text = metadata_sections(&all);
    let mut read = parse_sections(&text).unwrap();
    let mut want: Vec<Granted> = all.iter().map(Granted::from).collect();
    read.sort();
    want.sort();
    assert_eq!(read, want, "{text}");
    assert!(added(&text, &all).is_empty());
    assert!(parse_sections(&metadata_sections(&[])).unwrap().is_empty());
}

#[test]
fn widened_finds_an_added_entry_or_bus_name_and_accepts_equal_and_narrower() {
    let base = "[Application]\nname=play.x\n\n[Context]\nshared=ipc;\n\
                sockets=wayland;pulseaudio;\n\n[Session Bus Policy]\ncom.example.Bus=talk\n\n\
                [Extension a.b]\ndirectory=x\n";
    let ctx = |key, value| Grant {
        section: Section::Context,
        key,
        value,
    };
    let bus = |key, value| Grant {
        section: Section::SessionBusPolicy,
        key,
        value,
    };
    assert!(added(base, &[ctx("shared", "ipc"), ctx("sockets", "wayland")]).is_empty());
    assert!(added(base, &[]).is_empty());
    assert_eq!(
        added(base, &[ctx("shared", "network")]),
        vec!["[Context] shared=network".to_string()]
    );
    assert_eq!(
        added(base, &[bus("org.other.Bus", "talk")]),
        vec!["[Session Bus Policy] org.other.Bus=talk".to_string()]
    );
    // A broader policy of the same name is a widening, a narrower one is not.
    assert_eq!(added(base, &[bus("com.example.Bus", "own")]).len(), 1);
    assert!(added(base, &[bus("com.example.Bus", "see")]).is_empty());
    // A device `all` covers `dri`; a read-write path covers its `:ro`; not the other way round.
    let wide = "[Context]\ndevices=all;\nfilesystems=/run/media;\n";
    assert!(added(
        wide,
        &[ctx("devices", "dri"), ctx("filesystems", "/run/media:ro")]
    )
    .is_empty());
    let narrow = "[Context]\ndevices=dri;\nfilesystems=/run/media:ro;\n";
    assert_eq!(added(narrow, &[ctx("devices", "all")]).len(), 1);
    assert_eq!(added(narrow, &[ctx("filesystems", "/run/media")]).len(), 1);
    // A section the table cannot grant is not read: a key there is no grant.
    assert_eq!(
        added(
            "[Environment]\nshared=network\n",
            &[ctx("shared", "network")]
        )
        .len(),
        1
    );
}

// Fail closed (ADR-038): a deployed value the generator never writes is covered by an equal grant
// only, and a file that a union would misread is not read at all.

fn ctx(key: &'static str, value: &'static str) -> Grant {
    Grant {
        section: Section::Context,
        key,
        value,
    }
}

#[test]
fn a_deployed_bus_policy_none_does_not_cover_talk() {
    let talk = Grant {
        section: Section::SessionBusPolicy,
        key: "com.feralinteractive.GameMode",
        value: "talk",
    };
    let none = "[Session Bus Policy]
com.feralinteractive.GameMode=none
";
    assert_eq!(added(none, &[talk]).len(), 1);
}

#[test]
fn a_deployed_unknown_filesystem_mode_covers_only_itself() {
    let bogus = "[Context]
filesystems=/run/media:bogus;
";
    assert_eq!(added(bogus, &[ctx("filesystems", "/run/media")]).len(), 1);
    assert_eq!(
        added(bogus, &[ctx("filesystems", "/run/media:ro")]).len(),
        1
    );
    assert!(added(bogus, &[ctx("filesystems", "/run/media:bogus")]).is_empty());
}

#[test]
fn a_removal_entry_in_a_deployed_list_is_not_read() {
    let text = "[Context]
shared=network;!network;
";
    assert_eq!(widened(text, &[ctx("shared", "network")]), None);
    assert_eq!(parse_sections(text), None);
}

#[test]
fn a_repeated_key_or_permission_section_is_not_read() {
    assert_eq!(
        widened(
            "[Context]
shared=network;
shared=ipc;
",
            &[ctx("shared", "ipc")]
        ),
        None
    );
    assert_eq!(
        widened(
            "[Context]
shared=network;
[Context]
sockets=x11;
",
            &[]
        ),
        None
    );
    let bus = Grant {
        section: Section::SessionBusPolicy,
        key: "a.B",
        value: "see",
    };
    assert_eq!(
        widened(
            "[Session Bus Policy]
a.B=talk
a.B=see
",
            &[bus]
        ),
        None
    );
    // The same name in other sections, or an unrelated section twice, is fine.
    let ok = "[Context]
shared=ipc;
[Environment]
A=1
[Environment]
B=2
";
    assert_eq!(widened(ok, &[ctx("shared", "ipc")]), Some(vec![]));
}
