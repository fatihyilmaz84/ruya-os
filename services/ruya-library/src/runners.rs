//! The image's runners and the launcher's resolution for a `.play` game (RUY-903, RUY-959). Both
//! are the launcher's own code (`ruya_play_launch`): the runners are [`runners::scan_in`] of the
//! image's folder, the resolution is [`ruya_play_launch::dry_run`] with a runner choice. Nothing
//! here reads a `runner.json` or decides a runner by itself.
//!
//! The pure functions take the launcher's [`LaunchOs`], so the tests run them on its in-memory
//! fake; [`with_launch_os`] gives the real one, which only Linux has.

use std::path::Path;

use ruya_play_format::resolve::Override;
use ruya_play_launch::os::LaunchOs;
use ruya_play_launch::{runners, DryRun, Failure};

/// One runner of the image (Library1 `Runner` record).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Runner {
    pub family: String,
    /// `wine`, `proton`, `emulator` or `engine`.
    pub kind: String,
    pub version: String,
    pub licence: Option<String>,
    pub source_url: Option<String>,
}

/// The runners the launcher would accept under `dir`, in its order (folder name); a folder it
/// skips is logged by the scan and left out.
pub fn list(os: &dyn LaunchOs, dir: &str) -> Vec<Runner> {
    runners::scan_in(os, dir)
        .into_iter()
        .map(|found| Runner {
            family: found.runner.family,
            kind: found.runner.kind,
            version: found.runner.version,
            licence: found.runner.licence,
            source_url: found.runner.source_url,
        })
        .collect()
}

/// What the launch of a game would run with (the Library1 keys `play_runner`,
/// `play_runner_source`, `play_runner_tested`, `play_resolve_error`, `play_resolve_code`,
/// `play_fallback`). All none (and no fallback) for a native game and when nothing was resolved
/// (off Linux).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Resolution {
    /// `<family> <version>` of the runner the launch would use; none for a native game and when
    /// [`Self::resolve_error`] is set.
    pub runner: Option<String>,
    /// `bundled` or `system`, with [`Self::runner`].
    pub runner_source: Option<String>,
    /// The version the developer tested the component with.
    pub runner_tested: Option<String>,
    /// One sentence: why the launch would refuse (no runner, a runner too old, damaged files).
    pub resolve_error: Option<String>,
    /// The launcher's code of that refusal (`resolve.*`, `launch.*` or a format problem code),
    /// with [`Self::resolve_error`]: the shell words a refusal by it (RUY-905).
    pub resolve_code: Option<String>,
    /// The choice could not be honoured and [`Self::runner`] is the package default's (RUY-905).
    pub fallback: bool,
}

impl Resolution {
    /// What the launcher's dry run said.
    pub fn from_result(result: Result<DryRun, Failure>) -> Resolution {
        match result {
            Ok(DryRun { runner: Some(r) }) => Resolution {
                runner: Some(format!("{} {}", r.in_use.family, r.in_use.version)),
                runner_source: Some(r.in_use.source),
                runner_tested: r.tested,
                resolve_error: None,
                resolve_code: None,
                fallback: r.fallback,
            },
            Ok(DryRun { runner: None }) => Resolution::default(),
            Err(failure) => Resolution {
                resolve_error: Some(failure.message),
                resolve_code: Some(failure.code),
                ..Resolution::default()
            },
        }
    }
}

/// The launcher's resolution of the package tree at `files` against the runners under `runners`,
/// with the choice `over` (`--runner`).
pub fn resolve(os: &dyn LaunchOs, files: &str, runners: &str, over: Override) -> Resolution {
    Resolution::from_result(ruya_play_launch::dry_run(os, files, runners, over))
}

/// Runs `f` with the launcher's real file system. Only Linux has it; elsewhere (the Windows test
/// host) the answer is none, and the library resolves nothing and lists no runner.
#[cfg(target_os = "linux")]
pub fn with_launch_os<R>(f: impl FnOnce(&dyn LaunchOs) -> R) -> Option<R> {
    Some(f(&ruya_play_launch::linux::LinuxOs))
}

#[cfg(not(target_os = "linux"))]
pub fn with_launch_os<R>(f: impl FnOnce(&dyn LaunchOs) -> R) -> Option<R> {
    let _ = f;
    None
}

/// [`resolve`] on the real file system for the deployment `files` and the image's `runners`.
pub fn resolve_in_place(files: &Path, runners: &Path, over: Override) -> Option<Resolution> {
    let (files, runners) = (files.to_str()?, runners.to_str()?);
    with_launch_os(|os| resolve(os, files, runners, over))
}

/// [`list`] on the real file system.
pub fn list_in_place(dir: &Path) -> Vec<Runner> {
    dir.to_str()
        .and_then(|dir| with_launch_os(|os| list(os, dir)))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use ruya_play_format::runner::Entry;
    use ruya_play_launch::fake::FakeOs;
    use ruya_play_launch::plan::Root;
    use ruya_play_launch::state::RunnerInUse;

    use super::*;

    fn runner(source: &str, tested: Option<&str>) -> DryRun {
        DryRun {
            runner: Some(Root {
                path: "/r".into(),
                entry: Entry::default_for("wine"),
                in_use: RunnerInUse {
                    component: "wine".into(),
                    family: "wine".into(),
                    version: "10.2".into(),
                    source: source.into(),
                    hash: None,
                },
                tested: tested.map(str::to_owned),
                fallback: false,
            }),
        }
    }

    #[test]
    fn a_resolved_runner_fills_the_three_runner_fields() {
        let r = Resolution::from_result(Ok(runner("system", Some("9.20"))));
        assert_eq!(r.runner.as_deref(), Some("wine 10.2"));
        assert_eq!(r.runner_source.as_deref(), Some("system"));
        assert_eq!(r.runner_tested.as_deref(), Some("9.20"));
        assert_eq!(r.resolve_error, None);
        assert_eq!(r.resolve_code, None);
        assert!(!r.fallback);
    }

    /// RUY-905: the launcher's fallback flag reaches the resolution.
    #[test]
    fn a_choice_that_fell_back_is_flagged() {
        let mut dry = runner("system", None);
        dry.runner.as_mut().unwrap().fallback = true;
        let r = Resolution::from_result(Ok(dry));
        assert!(r.fallback);
        assert_eq!(r.runner.as_deref(), Some("wine 10.2"));
    }

    #[test]
    fn a_native_game_has_no_runner_fields() {
        let r = Resolution::from_result(Ok(DryRun { runner: None }));
        assert_eq!(r, Resolution::default());
    }

    #[test]
    fn a_refusal_is_its_sentence_and_nothing_else() {
        let r = Resolution::from_result(Err(Failure::new("resolve.system_too_old", "Too old.")));
        assert_eq!(r.resolve_error.as_deref(), Some("Too old."));
        assert_eq!(r.resolve_code.as_deref(), Some("resolve.system_too_old"));
        assert_eq!(r.runner, None);
        assert!(!r.fallback);
    }

    const DIR: &str = "/usr/lib/ruyaos/play/runners";

    /// RUY-959: the runners are the launcher's scan: two good folders in name order, a broken
    /// `runner.json` left out with a line in the log.
    #[test]
    fn the_runners_are_the_folders_the_launcher_accepts() {
        let mut os = FakeOs::new();
        os.file(
            &format!("{DIR}/ProtonGE11/runner.json"),
            r#"{"format":1,"family":"proton-ge","kind":"proton","version":"GE-Proton11-12","arch":"x86_64","entry":{"proton":"proton"},"licence":"BSD-3-Clause","source_url":"https://example.org/ge"}"#,
        );
        os.file(
            &format!("{DIR}/ProtonGE11/proton"),
            "#!/usr/bin/env python3",
        );
        os.file(&format!("{DIR}/Broken/runner.json"), "{ not json");
        os.file(
            &format!("{DIR}/Wine10/runner.json"),
            r#"{"format":1,"family":"wine","kind":"wine","version":"10.0","arch":"x86_64","entry":{"wine":"bin/wine","wineserver":"bin/wineserver"}}"#,
        );
        os.file(&format!("{DIR}/Wine10/bin/wine"), "elf");
        os.file(&format!("{DIR}/Wine10/bin/wineserver"), "elf");
        let got = list(&os, DIR);
        assert_eq!(
            got,
            vec![
                Runner {
                    family: "proton-ge".into(),
                    kind: "proton".into(),
                    version: "GE-Proton11-12".into(),
                    licence: Some("BSD-3-Clause".into()),
                    source_url: Some("https://example.org/ge".into()),
                },
                Runner {
                    family: "wine".into(),
                    kind: "wine".into(),
                    version: "10.0".into(),
                    licence: None,
                    source_url: None,
                },
            ]
        );
        let lines = os.lines.borrow();
        assert!(
            lines
                .iter()
                .any(|l| l.contains("Broken/runner.json") && l.contains("runner skipped")),
            "{lines:?}"
        );
    }

    #[test]
    fn no_runners_folder_is_no_runners() {
        assert_eq!(list(&FakeOs::new(), DIR), Vec::new());
    }
}
