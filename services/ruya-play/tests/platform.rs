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
use ruya_play_format::manifest::Component;
use ruya_play_format::problem::Problems;
use ruya_play_format::resolve::{
    major_of, resolve_one, Chosen, Override, SystemRunner, Unresolved,
};
use ruya_play_format::runner::{
    is_system_runner_name, parse_runner, Pin, Prune, RunnerJson, FILE_NAME,
};
use ruya_play_trust::{check_ceiling, Tier};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// Where the image keeps the console's extension trees (ADR-038).
const USR_TREES: &str = "/usr/lib/ruyaos/play";
/// Where Flatpak looks for unmaintained extensions.
const EXTENSION_ROOT: &str = "/var/lib/flatpak/extension";
/// Steam's extension point for compatibility tools, from the Steam Flathub manifest
/// (com.valvesoftware.Steam.yml: `subdirectories: true`, `directory: share/steam/compatibilitytools.d`,
/// `version: stable`). Every Proton runner of the image is linked into it (RUY-35).
const STEAM_TOOL_POINT: &str = "com.valvesoftware.Steam.CompatibilityTool";
const STEAM_TOOL_BRANCH: &str = "stable";

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

/// The runner folders of `image/play/runners/`, in name order.
fn image_runner_names() -> Vec<String> {
    let runners = repo("image/play/runners");
    let mut names: Vec<String> = std::fs::read_dir(&runners)
        .unwrap_or_else(|e| panic!("{} cannot be read: {e}", runners.display()))
        .map(|e| e.unwrap())
        .filter(|e| e.file_type().unwrap().is_dir())
        .map(|e| e.file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

/// The `runner.json` of the image's runner `name`, read by the one parser.
fn image_runner(name: &str) -> RunnerJson {
    let path = repo("image/play/runners").join(name).join(FILE_NAME);
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let mut problems = Problems::new();
    let parsed = parse_runner(&bytes, &format!("{name}/{FILE_NAME}"), &mut problems);
    parsed.unwrap_or_else(|| panic!("{name}: {:?}", problems.finish()))
}

/// How many GE-Proton majors the image keeps (docs/image-packages.md, "Retention"): the current
/// one and the one before it, so a major bump never takes away the runner an installed game ran on.
const GE_PROTON_MAJORS_KEPT: usize = 2;

/// The retention rule of the image's runners, over (folder, family, version): at least one
/// `proton-ge` runner (the default Windows runner, ADR-025), at most [`GE_PROTON_MAJORS_KEPT`],
/// each of another major. `Err` says what breaks it.
fn ge_proton_retention(runners: &[(&str, &str, &str)]) -> Result<(), String> {
    let mut majors: Vec<(u64, &str)> = Vec::new();
    for (name, family, version) in runners {
        if *family != "proton-ge" {
            continue;
        }
        let major = major_of(version);
        if let Some((_, other)) = majors.iter().find(|(m, _)| *m == major) {
            return Err(format!("{other} and {name} are both GE-Proton {major}"));
        }
        majors.push((major, name));
    }
    if majors.is_empty() {
        return Err("no GE-Proton runner (the default Windows runner)".into());
    }
    if majors.len() > GE_PROTON_MAJORS_KEPT {
        let names: Vec<&str> = majors.iter().map(|(_, n)| *n).collect();
        return Err(format!(
            "{} GE-Proton majors ({}): the image keeps at most {GE_PROTON_MAJORS_KEPT}, the current one and the one before",
            majors.len(),
            names.join(", ")
        ));
    }
    Ok(())
}

#[test]
fn the_retention_rule_keeps_one_or_two_ge_proton_majors() {
    let wine = ("Wine11", "wine", "wine-11.0");
    let ge11 = ("ProtonGE11", "proton-ge", "GE-Proton11-13");
    let ge10 = ("ProtonGE10", "proton-ge", "GE-Proton10-30");
    let ge9 = ("ProtonGE9", "proton-ge", "GE-Proton9-27");
    assert_eq!(ge_proton_retention(&[ge11, wine]), Ok(()));
    assert_eq!(ge_proton_retention(&[ge10, ge11, wine]), Ok(()));
    let third = ge_proton_retention(&[ge10, ge11, ge9, wine]).unwrap_err();
    assert!(third.starts_with("3 GE-Proton majors"), "{third}");
    let none = ge_proton_retention(&[wine]).unwrap_err();
    assert!(none.starts_with("no GE-Proton runner"), "{none}");
    let twice = ge_proton_retention(&[ge11, ("ProtonGE11b", "proton-ge", "GE-Proton11-9")]);
    assert_eq!(
        twice,
        Err("ProtonGE11 and ProtonGE11b are both GE-Proton 11".into())
    );
}

#[test]
fn the_image_runners_keep_the_retention_rule() {
    let parsed: Vec<(String, RunnerJson)> = image_runner_names()
        .into_iter()
        .map(|n| {
            let r = image_runner(&n);
            (n, r)
        })
        .collect();
    let table: Vec<(&str, &str, &str)> = parsed
        .iter()
        .map(|(n, r)| (n.as_str(), r.family.as_str(), r.version.as_str()))
        .collect();
    assert_eq!(ge_proton_retention(&table), Ok(()), "image/play/runners/");
}

/// A Windows component with `source: system` and no bundled copy.
fn system_component(kind: &str) -> Component {
    Component {
        id: kind.into(),
        kind: kind.into(),
        source: "system".into(),
        min: None,
        tested: None,
        max_major: None,
        bundled: None,
    }
}

/// The image's own runners serve a package asking for `wine` and one asking for `proton`
/// (05 section 6.2), each only through its own family: without the image's Wine a `wine` package
/// has no system runner, and without its GE-Proton a `proton` package has none.
#[test]
fn the_image_runners_serve_a_system_wine_and_a_system_proton_package() {
    let image: Vec<SystemRunner> = image_runner_names()
        .iter()
        .map(|n| {
            let r = image_runner(n);
            SystemRunner::new(&r.family, &r.version)
        })
        .collect();
    let version_of = |family: &str| -> String {
        let found = image.iter().find(|s| s.family == family);
        found
            .unwrap_or_else(|| panic!("the image has no {family} runner"))
            .version
            .clone()
    };
    let cases = [("wine", "wine"), ("proton", "proton-ge")];
    for (kind, family) in cases {
        let c = system_component(kind);
        let all = resolve_one(&c, &image, &BTreeMap::new(), Override::PackageDefault);
        assert_eq!(
            all.outcome,
            Ok(Chosen::System {
                family: family.into(),
                version: version_of(family)
            }),
            "{kind} with every image runner"
        );
        for (other_kind, other_family) in cases {
            let without: Vec<SystemRunner> = image
                .iter()
                .filter(|s| s.family != other_family)
                .cloned()
                .collect();
            let r = resolve_one(&c, &without, &BTreeMap::new(), Override::PackageDefault);
            if other_kind == kind {
                assert!(
                    matches!(r.outcome, Err(Unresolved::NoSystemRunner { .. })),
                    "{kind} without {other_family}: {:?}",
                    r.outcome
                );
            } else {
                assert_eq!(r.outcome, all.outcome, "{kind} without {other_family}");
            }
        }
    }
}

/// Every runner folder of `image/play/runners/` (`image/play/install-runners.sh` installs each one)
/// has a pin of the release ([`Pin::parse`]), a `runner.json` the one
/// parser accepts, a name that can be the last part of `org.ruyaos.Play.Runner.<Name>`, and its `L+`
/// line; and every runner line of the tmpfiles.d file has its folder.
#[test]
fn the_image_runners_are_valid_and_linked() {
    let runners = repo("image/play/runners");
    let names = image_runner_names();
    assert!(!names.is_empty(), "the image ships no runner");
    let (_, conf) = conf();
    let have = links(&conf);
    for name in &names {
        assert!(is_system_runner_name(name), "{name}: not a runner name");
        let dir = runners.join(name);
        let pin = std::fs::read_to_string(dir.join("pin")).expect("a pin file");
        // The one grammar (`Pin::parse`); `install-runners.sh check_pin` holds to the same verdicts.
        Pin::parse(&pin).unwrap_or_else(|e| panic!("{name}: {e}"));
        let parsed = image_runner(name);
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
        // A Proton runner is also Steam's compatibility tool: the same tree, one more line.
        let steam = (
            format!("{EXTENSION_ROOT}/{STEAM_TOOL_POINT}.{name}/{ARCH}/{STEAM_TOOL_BRANCH}"),
            format!("{USR_TREES}/runners/{name}"),
        );
        assert_eq!(
            have.contains(&steam),
            parsed.kind == "proton",
            "{name} ({}): the Steam line {steam:?} belongs to Proton runners only",
            parsed.kind
        );
    }
    let prefix = format!("{EXTENSION_ROOT}/org.ruyaos.Play.Runner.");
    for (path, _) in have.iter().filter(|(p, _)| p.starts_with(&prefix)) {
        let name = path[prefix.len()..].split('/').next().unwrap_or("");
        assert!(
            names.iter().any(|n| n == name),
            "{path} links a runner image/play/runners/ does not have"
        );
    }
    let steam_prefix = format!("{EXTENSION_ROOT}/{STEAM_TOOL_POINT}.");
    for (path, target) in have.iter().filter(|(p, _)| p.starts_with(&steam_prefix)) {
        let name = path[steam_prefix.len()..].split('/').next().unwrap_or("");
        assert!(
            names.iter().any(|n| n == name) && *target == format!("{USR_TREES}/runners/{name}"),
            "{path} -> {target}: not a runner image/play/runners/ has"
        );
    }
}

/// A runner folder's optional `prune` file (`image/play/install-runners.sh` deletes what it names
/// before the runner hash is computed, RUY-1039) holds to the one grammar ([`Prune::parse`]), and
/// GE-Proton's prunes the libxkbcommon and libxkbregistry it bundles: they shadow the runtime's newer
/// copies and break its SDL3 (no controller reaches a Windows game).
#[test]
fn the_image_runners_prune_files_hold_to_the_grammar() {
    let runners = repo("image/play/runners");
    for name in image_runner_names() {
        let path = runners.join(&name).join("prune");
        if let Ok(text) = std::fs::read_to_string(&path) {
            Prune::parse(&text).unwrap_or_else(|e| panic!("{name}/prune: {e}"));
        }
    }
    let ge = std::fs::read_to_string(runners.join("ProtonGE11").join("prune"))
        .expect("ProtonGE11 has a prune file");
    let globs = Prune::parse(&ge).expect("a prune file").globs;
    for lib in ["libxkbcommon.so*", "libxkbregistry.so*"] {
        let want = format!("files/lib/x86_64-linux-gnu/{lib}");
        assert!(globs.contains(&want), "ProtonGE11/prune lacks {want}");
    }
}

/// The shell's mock library backend lists the image's runners (`pinnedRunners()`): the versions and
/// source URLs it hard-codes are the ones the image pins. Per runner folder, `runner.json`'s version
/// is in the pin's URL and root and in the source URL, and the mock source holds the version and the
/// source URL as string literals (comments and translations are not read).
#[test]
fn the_runner_pins_runner_json_and_the_shell_mock_agree() {
    let mock_path = repo("shell/src/library/MockLibraryBackend.cpp");
    let mock = std::fs::read_to_string(&mock_path).expect("the mock library backend");
    let mut seen = 0;
    for name in image_runner_names() {
        let runner = image_runner(&name);
        let pin_text = std::fs::read_to_string(repo("image/play/runners").join(&name).join("pin"))
            .expect("a pin file");
        let pin = Pin::parse(&pin_text).unwrap_or_else(|e| panic!("{name}: {e}"));
        let source = runner.source_url.expect("a source_url");
        assert!(
            pin.url.contains(&runner.version),
            "{name}: pin url {} lacks runner.json's version {}",
            pin.url,
            runner.version
        );
        assert!(
            pin.root.starts_with(&runner.version),
            "{name}: pin root {} does not start with runner.json's version {}",
            pin.root,
            runner.version
        );
        assert!(
            source.contains(&runner.version),
            "{name}: source_url {source} lacks version {}",
            runner.version
        );
        for (what, value) in [("version", &runner.version), ("source_url", &source)] {
            assert!(
                mock.contains(&format!("QStringLiteral(\"{value}\")")),
                "{name}: {} has no literal for {what} {value}; update pinnedRunners() with the pin",
                mock_path.display()
            );
        }
        seen += 1;
    }
    assert!(seen >= 2, "the image pins {seen} runners");
}
