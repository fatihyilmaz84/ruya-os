//! The architect's check for ADR-038 (RUY-900): every extension point of the console's own
//! (`org.ruyaos.*`) that the generated metadata declares, and the `command=` inside one, is backed
//! by an `L+` line of `image/rootfs/usr/lib/tmpfiles.d/ruya-play-platform.conf` that links the
//! unmaintained extension under `/var/lib/flatpak/extension/` to its tree on `/usr`. A point with
//! `subdirectories=true` (the runners) needs at least one `<id>.<Name>` line. The freedesktop
//! points (`org.freedesktop.Platform.Compat.i386`, `GL32`) come from the runtime's remote, not
//! from `/usr`, and are not checked here.
//!
//! The image's runners are data (RUY-34): one folder per runner in `image/play/runners/` (its pin
//! and its `runner.json`), and one `L+` line per folder; `the_image_runners_are_valid_and_linked`
//! holds the folders and the lines together, both ways.

mod common;

use common::fx::check;
use common::Fx;
use ruya_play::service::commit::{metadata, ARCH, LAUNCH_COMMAND};
use ruya_play_format::problem::Problems;
use ruya_play_format::runner::{is_system_runner_name, parse_runner, FILE_NAME};
use ruya_play_trust::{check_ceiling, Tier};
use std::path::PathBuf;

/// Where the image keeps the console's extension trees (ADR-038).
const USR_TREES: &str = "/usr/lib/ruyaos/play";
/// Where Flatpak looks for unmaintained extensions.
const EXTENSION_ROOT: &str = "/var/lib/flatpak/extension";

/// One line the file must have: the link `path` to `target`. With `per_name`, any number of
/// lines `<path>.<Name>/...` to `<target>/<Name>` (at least one).
#[derive(Debug, PartialEq, Eq)]
struct Expected {
    id: String,
    branch: String,
    directory: String,
    per_name: bool,
}

impl Expected {
    fn path(&self, name: Option<&str>) -> String {
        let id = match name {
            Some(n) => format!("{}.{n}", self.id),
            None => self.id.clone(),
        };
        format!("{EXTENSION_ROOT}/{id}/{ARCH}/{}", self.branch)
    }

    fn target(&self, name: Option<&str>) -> String {
        match name {
            Some(n) => format!("{USR_TREES}/{}/{n}", self.directory),
            None => format!("{USR_TREES}/{}", self.directory),
        }
    }
}

/// The `[Extension <id>]` sections of a metadata file: id, directory, version, subdirectories.
fn points(metadata: &str) -> Vec<Expected> {
    let mut out: Vec<Expected> = Vec::new();
    for line in metadata.lines() {
        if let Some(id) = line
            .strip_prefix("[Extension ")
            .and_then(|l| l.strip_suffix(']'))
        {
            out.push(Expected {
                id: id.to_string(),
                branch: String::new(),
                directory: String::new(),
                per_name: false,
            });
        } else if let (Some(p), Some((key, value))) = (out.last_mut(), line.split_once('=')) {
            match key {
                "directory" => p.directory = value.to_string(),
                "version" => p.branch = value.to_string(),
                "subdirectories" => p.per_name = value == "true",
                _ => {}
            }
        }
    }
    out
}

/// What the generated metadata of a native and of a Windows package needs linked.
fn expected() -> Vec<Expected> {
    let mut out: Vec<Expected> = Vec::new();
    for fx in [Fx::minimal(), Fx::wine_full()] {
        let m = check(&fx).expect("the fixture validates").manifest;
        let a = check_ceiling(Tier::Developer, &m.permissions).expect("under the ceiling");
        for p in points(&metadata(&m, &a)) {
            if p.id.starts_with("org.ruyaos.") && !out.contains(&p) {
                out.push(p);
            }
        }
    }
    out
}

#[test]
fn the_expected_lines() {
    let lines: Vec<(String, String, bool)> = expected()
        .iter()
        .map(|e| (e.path(None), e.target(None), e.per_name))
        .collect();
    assert_eq!(
        lines,
        vec![
            (
                "/var/lib/flatpak/extension/org.ruyaos.Play.Launcher/x86_64/1".to_string(),
                "/usr/lib/ruyaos/play/launcher".to_string(),
                false
            ),
            (
                "/var/lib/flatpak/extension/org.ruyaos.Play.Runner/x86_64/1".to_string(),
                "/usr/lib/ruyaos/play/runners".to_string(),
                true
            ),
        ]
    );
    // The command runs from a linked point: the launcher's.
    let launcher = &expected()[0];
    assert!(LAUNCH_COMMAND.starts_with(&format!("/app/{}/", launcher.directory)));
}

/// The `L+` lines of a tmpfiles.d file: (path, argument).
fn links(conf: &str) -> Vec<(String, String)> {
    conf.lines()
        .map(str::trim)
        .filter(|l| !l.starts_with('#'))
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            (f.len() >= 7 && f[0] == "L+").then(|| (f[1].to_string(), f[6].to_string()))
        })
        .collect()
}

fn repo(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel)
}

/// The real tmpfiles.d file of the image.
fn conf() -> (PathBuf, String) {
    let path = repo("image/rootfs/usr/lib/tmpfiles.d/ruya-play-platform.conf");
    let conf = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{} cannot be read: {e}", path.display()));
    (path, conf)
}

#[test]
fn the_tmpfiles_links_every_point() {
    let (path, conf) = conf();
    let have = links(&conf);
    let mut missing = Vec::new();
    for e in expected() {
        let linked = if e.per_name {
            have.iter().any(|(p, t)| {
                let prefix = format!("{EXTENSION_ROOT}/{}.", e.id);
                p.strip_prefix(&prefix)
                    .and_then(|rest| rest.split_once('/'))
                    .is_some_and(|(name, _)| *p == e.path(Some(name)) && *t == e.target(Some(name)))
            })
        } else {
            have.contains(&(e.path(None), e.target(None)))
        };
        if !linked {
            missing.push(e.id);
        }
    }
    assert!(
        missing.is_empty(),
        "{} has no L+ line for {missing:?}",
        path.display()
    );
}

#[test]
fn the_link_parser_reads_tmpfiles_lines() {
    let conf = "# comment\n\
                L+ /var/lib/flatpak/extension/a/x86_64/1 - - - - /usr/lib/ruyaos/play/launcher\n\
                d /var/lib/x 0755 root root -\n";
    assert_eq!(
        links(conf),
        vec![(
            "/var/lib/flatpak/extension/a/x86_64/1".to_string(),
            "/usr/lib/ruyaos/play/launcher".to_string()
        )]
    );
}

/// The value of the one `key=value` line of a pin file.
fn pin_value<'a>(pin: &'a str, key: &str) -> Option<&'a str> {
    let mut values = pin
        .lines()
        .filter_map(|l| l.strip_prefix(key)?.strip_prefix('='));
    let v = values.next();
    v.filter(|_| values.next().is_none())
}

/// Every runner folder of `image/play/runners/` (`image/play/install-runners.sh` installs each one)
/// has a pin of the release (an https URL, a SHA-256, the archive's folder), a `runner.json` the one
/// parser accepts, a name that can be the last part of `org.ruyaos.Play.Runner.<Name>`, and its `L+`
/// line; and every runner line of the tmpfiles.d file has its folder.
#[test]
fn the_image_runners_are_valid_and_linked() {
    let runners = repo("image/play/runners");
    let mut names: Vec<String> = std::fs::read_dir(&runners)
        .unwrap_or_else(|e| panic!("{} cannot be read: {e}", runners.display()))
        .map(|e| e.unwrap())
        .filter(|e| e.file_type().unwrap().is_dir())
        .map(|e| e.file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert!(!names.is_empty(), "the image ships no runner");
    let (_, conf) = conf();
    let have = links(&conf);
    for name in &names {
        assert!(is_system_runner_name(name), "{name}: not a runner name");
        let dir = runners.join(name);
        let pin = std::fs::read_to_string(dir.join("pin")).expect("a pin file");
        let url = pin_value(&pin, "url").unwrap_or_else(|| panic!("{name}: one url= line"));
        assert!(url.starts_with("https://"), "{name}: {url}");
        let sha = pin_value(&pin, "sha256").unwrap_or_else(|| panic!("{name}: one sha256= line"));
        assert!(
            sha.len() == 64 && sha.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')),
            "{name}: {sha}"
        );
        let root = pin_value(&pin, "root").unwrap_or_else(|| panic!("{name}: one root= line"));
        assert!(
            !root.is_empty() && !root.contains('/') && root != "..",
            "{name}: {root}"
        );
        let bytes = std::fs::read(dir.join(FILE_NAME)).expect("a runner.json");
        let mut problems = Problems::new();
        let parsed = parse_runner(&bytes, &format!("{name}/{FILE_NAME}"), &mut problems);
        let parsed = parsed.unwrap_or_else(|| panic!("{name}: {:?}", problems.finish()));
        // Settings > About shows each runner's licences and source (ADR-025's notice duty).
        assert!(
            parsed.licence.is_some() && parsed.source_url.is_some(),
            "{name}: runner.json needs licence and source_url"
        );
        let link = (
            format!("{EXTENSION_ROOT}/org.ruyaos.Play.Runner.{name}/{ARCH}/1"),
            format!("{USR_TREES}/runners/{name}"),
        );
        assert!(have.contains(&link), "{name}: no line {link:?}");
    }
    let prefix = format!("{EXTENSION_ROOT}/org.ruyaos.Play.Runner.");
    for (path, _) in have.iter().filter(|(p, _)| p.starts_with(&prefix)) {
        let name = path[prefix.len()..].split('/').next().unwrap_or("");
        assert!(
            names.iter().any(|n| n == name),
            "{path} links a runner image/play/runners/ does not have"
        );
    }
}
