//! RUY-828 acceptance: the helper split (05 §7.3). The service side never opens a package; a
//! hostile helper (forged lines, a forged staged tree, a forged `meta/`) ends `failed` with nothing
//! recorded, nothing committed and nothing left; a package that changes between the two opens is
//! `source.changed`; `Inspect` carries the vetted art of the sample package.

mod common;

use common::*;
use ruya_play::core::helper::{self, Mode, MAX_LINE_BYTES, MAX_PROBLEMS};
use ruya_play::core::installed::MemoryInstalled;
use ruya_play::{
    Canceller, Exit, Helper, InstalledBuilds, JobResult, JobStatus, MethodStatus, Request,
};
use ruya_play_trust::TrustStore;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, OnceLock};

const ID: &str = "com.example.mini";

/// The package of `fx`, which may only be opened inside a helper run; `opens` counts the opens.
fn guarded(fx: &Fx, opens: Arc<AtomicU32>) -> Pkg {
    let inner = Pkg::signed(fx);
    Pkg::Custom(Arc::new(move || {
        assert!(helper::inside(), "the service side opened the package");
        opens.fetch_add(1, Ordering::SeqCst);
        inner.open().expect("the fixture opens")
    }))
}

#[test]
fn the_service_side_never_opens_the_package() {
    let opens = Arc::new(AtomicU32::new(0));
    let mut h = Setup::with(guarded(&game(), Arc::clone(&opens))).build();
    let (st, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(st, MethodStatus::Ok);
    assert_eq!(report.unwrap().verdict, JobStatus::Ok);
    assert_eq!(
        opens.load(Ordering::SeqCst),
        1,
        "Inspect opens it once, in the helper"
    );
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    // The install opens it twice, both times in the helper: inspect, then unpack.
    assert_eq!(opens.load(Ordering::SeqCst), 3);
    assert!(!helper::inside());
    h.assert_events_ordered();
}

/// The sample `samples/hello-play-native` (RUY-105) as a fixture: its manifest and its art, with a
/// stub where `build.sh` puts the program.
fn sample() -> Fx {
    let root =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../samples/hello-play-native/package");
    let read = |p: &str| std::fs::read(root.join(p)).expect("the sample is in the tree");
    let mut fx = Fx::minimal();
    fx.manifest = serde_json::from_slice(&read("play.json")).unwrap();
    fx.files = vec![
        ("art/icon.png".into(), read("art/icon.png")),
        ("art/hero.png".into(), read("art/hero.png")),
        (
            "payload/hello-game".into(),
            b"stub payload, not a real program\n".to_vec(),
        ),
    ];
    fx.exec.insert("payload/hello-game".into());
    fx
}

#[test]
fn inspect_carries_the_vetted_art_of_the_sample() {
    let mut h = Setup::with(Pkg::signed(&sample())).build();
    let (st, report) = h.importer.inspect(&pkg_path("game.play"));
    assert_eq!(st, MethodStatus::Ok);
    let report = report.unwrap();
    assert_eq!(report.verdict, JobStatus::Ok, "{:?}", report.problems);
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    let slots: Vec<&str> = report.art.iter().map(|a| a.slot.as_str()).collect();
    assert_eq!(slots, vec!["icon", "hero"]);
    for a in &report.art {
        assert!(!a.files.is_empty(), "{} has no files", a.slot);
        for f in &a.files {
            assert!(f.starts_with(&h.cfg.inspect), "{}", f.display());
            assert!(std::fs::metadata(f).unwrap().len() > 0, "{}", f.display());
        }
    }
    // Only the vetted art stays: no root files, no copied art sources, no staging, no job.
    let left = listing(&h.cfg.inspect);
    assert!(
        left.iter()
            .all(|p| p == "inspect-1" || p.starts_with("inspect-1/art")),
        "{left:?}"
    );
    assert_eq!(h.staging(), Vec::<String>::new());
    assert!(!h.cfg.jobs_file().exists());
    assert_eq!(h.free.calls.load(Ordering::SeqCst), 0);
    // The install's own inspect folder goes with the job; the preview stays.
    let r = h.install();
    assert_eq!(r.status, JobStatus::Ok, "{:?}", r.problems);
    let top: Vec<String> = listing(&h.cfg.inspect)
        .into_iter()
        .filter(|p| !p.contains('/'))
        .collect();
    assert_eq!(top, vec!["inspect-1"]);
}

#[test]
fn inspect_keeps_the_newest_previews_and_nothing_of_a_refusal() {
    let h = Setup::with(Pkg::signed(&game())).build();
    for _ in 0..ruya_play::core::importer::MAX_PREVIEWS + 2 {
        assert_eq!(
            h.importer.inspect(&pkg_path("game.play")).0,
            MethodStatus::Ok
        );
    }
    let top: Vec<String> = listing(&h.cfg.inspect)
        .into_iter()
        .filter(|p| !p.contains('/'))
        .collect();
    assert_eq!(
        top,
        vec!["inspect-3", "inspect-4", "inspect-5", "inspect-6"]
    );

    let h = Setup::with(Pkg::Zip(b"not a zip".to_vec())).build();
    let report = h.importer.inspect(&pkg_path("game.play")).1.unwrap();
    assert_eq!(report.problems[0].code, "zip.not_a_zip");
    assert!(report.art.is_empty());
    assert_eq!(listing(&h.cfg.inspect), Vec::<String>::new());
}

/// Runs the real helper, then changes what it staged before the service looks.
struct Tamper {
    inner: Box<dyn Helper>,
    mode: Mode,
    act: fn(&Path),
}

impl Helper for Tamper {
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit {
        let exit = self.inner.run(request, cancel, on_output);
        if request.mode == self.mode {
            (self.act)(Path::new(&request.staging));
        }
        exit
    }
}

/// A harness whose helper is wrapped by `wrap`, with stores the test can look into.
fn hostile(
    wrap: impl FnOnce(Box<dyn Helper>) -> Box<dyn Helper> + 'static,
) -> (Harness, SharedTrust, SharedInstalled) {
    let (trust, installed) = (SharedTrust::default(), SharedInstalled::default());
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.stores = Some((trust.clone(), installed.clone()));
    setup.wrap_helper = Some(Box::new(wrap));
    (setup.build(), trust, installed)
}

#[track_caller]
fn assert_refused(
    h: &Harness,
    trust: &SharedTrust,
    installed: &SharedInstalled,
    r: &JobResult,
    status: JobStatus,
    code: &str,
) {
    assert_eq!(r.status, status, "{:?}", r.problems);
    assert_eq!(codes(r), vec![code.to_string()], "{:?}", r.problems);
    h.assert_nothing_left();
    assert_eq!(
        listing(&h.cfg.inspect),
        Vec::<String>::new(),
        "an inspect folder is left"
    );
    assert_eq!(
        trust.inner.lock().unwrap().get(ID).unwrap(),
        None,
        "a key was recorded"
    );
    assert_eq!(
        installed.inner.lock().unwrap().build_of(ID).unwrap(),
        None,
        "a build was recorded"
    );
    h.assert_events_ordered();
}

fn tree(staging: &Path) -> PathBuf {
    staging.join("tree")
}

/// What a hostile helper does to its staging folder, by name.
type Forgery = (&'static str, fn(&Path));

#[test]
fn a_forged_staged_tree_is_refused_by_the_service() {
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut cases: Vec<Forgery> = vec![
        ("an extra file", |s| {
            std::fs::write(tree(s).join("payload").join("extra.bin"), b"x").unwrap()
        }),
        ("a size change", |s| {
            let p = tree(s).join("payload").join("game");
            let mut b = std::fs::read(&p).unwrap();
            b.push(b'\n');
            std::fs::write(p, b).unwrap();
        }),
        ("the same size, other bytes", |s| {
            let p = tree(s).join("payload").join("data.bin");
            let mut b = std::fs::read(&p).unwrap();
            b[0] ^= 0xff;
            std::fs::write(p, b).unwrap();
        }),
        ("a missing file", |s| {
            std::fs::remove_file(tree(s).join("payload").join("game")).unwrap()
        }),
        ("an entry next to tree and art", |s| {
            std::fs::create_dir(s.join("meta")).unwrap()
        }),
        ("no tree at all", |s| {
            std::fs::remove_dir_all(tree(s)).unwrap()
        }),
        ("an extra art file", |s| {
            std::fs::write(s.join("art").join("evil.webp"), b"x").unwrap()
        }),
        ("a missing art file", |s| {
            std::fs::remove_file(s.join("art").join("icon-512.webp")).unwrap()
        }),
        // RUY-829: a vetted file is bounded and starts as its format does.
        ("an art file larger than its output can be", |s| {
            let p = s.join("art").join("icon-128.webp");
            let mut b = std::fs::read(&p).unwrap();
            b.resize(128 * 128 * 4 + 64 * 1024 + 1, 0);
            std::fs::write(p, b).unwrap();
        }),
        ("an art file that is not WebP", |s| {
            std::fs::write(
                s.join("art").join("icon-256.webp"),
                b"\x89PNG\r\n\x1a\n not a webp at all",
            )
            .unwrap()
        }),
        ("a WebP whose RIFF size is not the file's", |s| {
            let p = s.join("art").join("icon-512.webp");
            let mut b = std::fs::read(&p).unwrap();
            b.extend_from_slice(b"trailing bytes");
            std::fs::write(p, b).unwrap();
        }),
    ];
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        cases.push(("a link instead of a file", |s| {
            let p = tree(s).join("payload").join("game");
            std::fs::remove_file(&p).unwrap();
            std::os::unix::fs::symlink("/etc/passwd", p).unwrap();
        }));
        cases.push(("mode 4755", |s| {
            let p = tree(s).join("payload").join("game");
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o4755)).unwrap();
        }));
        cases.push(("a setuid art file", |s| {
            let p = s.join("art").join("icon-512.webp");
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o4644)).unwrap();
        }));
    }
    for (what, act) in cases {
        let (mut h, trust, installed) = hostile(move |inner| {
            Box::new(Tamper {
                inner,
                mode: Mode::Install,
                act,
            })
        });
        let r = h.install();
        assert_eq!(
            codes(&r),
            vec!["staging.changed".to_string()],
            "{what}: {:?}",
            r.problems
        );
        assert_refused(
            &h,
            &trust,
            &installed,
            &r,
            JobStatus::Failed,
            "staging.changed",
        );
    }
}

#[test]
fn forged_root_files_are_verified_again_by_the_service() {
    // The helper's meta/ is read back and its signature checked with the service's keys.
    let (mut h, trust, installed) = hostile(|inner| {
        Box::new(Tamper {
            inner,
            mode: Mode::Inspect,
            act: |s| {
                let p = s.join("meta").join("play.json");
                let text = std::fs::read_to_string(&p).unwrap();
                std::fs::write(p, text.replace("\"Mini\"", "\"Mega\"")).unwrap();
            },
        })
    });
    let r = h.install();
    assert_eq!(r.status, JobStatus::BadSignature, "{:?}", r.problems);
    assert!(r.problems[0].code.starts_with("sig."), "{:?}", r.problems);
    h.assert_nothing_left();
    assert_eq!(listing(&h.cfg.inspect), Vec::<String>::new());
    assert_eq!(trust.inner.lock().unwrap().get(ID).unwrap(), None);
    assert_eq!(installed.inner.lock().unwrap().build_of(ID).unwrap(), None);
}

/// Answers `install` runs (or every run) with fixed output and a fixed exit; the rest goes to the
/// real helper. With `cancel`, it cancels the job first.
struct Scripted {
    real: Box<dyn Helper>,
    only_install: bool,
    out: Vec<u8>,
    exit: Exit,
    cancel: Option<Arc<OnceLock<Canceller>>>,
}

impl Helper for Scripted {
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit {
        if self.only_install && request.mode != Mode::Install {
            return self.real.run(request, cancel, on_output);
        }
        if let Some(c) = &self.cancel {
            assert_eq!(c.get().unwrap().cancel(&request.job), MethodStatus::Ok);
        }
        let _ = on_output(&self.out);
        self.exit.clone()
    }
}

fn scripted(
    out: Vec<u8>,
    exit: Exit,
    cancel: Option<Arc<OnceLock<Canceller>>>,
) -> (Harness, SharedTrust, SharedInstalled) {
    hostile(move |real| {
        Box::new(Scripted {
            real,
            only_install: true,
            out,
            exit,
            cancel,
        })
    })
}

fn lines(v: &[&str]) -> Vec<u8> {
    v.iter()
        .map(|l| format!("{l}\n"))
        .collect::<String>()
        .into_bytes()
}

const OK: &str = r#"{"type":"result","outcome":"ok"}"#;

#[test]
fn a_helper_that_breaks_its_contract_fails_the_job() {
    let mut too_long = vec![b' '; MAX_LINE_BYTES + 1];
    too_long.push(b'\n');
    let problem = r#"{"type":"problem","code":"art.broken","path":"art/icon.png","message":"m"}"#;
    let mut too_many = vec![problem; MAX_PROBLEMS + 1];
    too_many.push(r#"{"type":"result","outcome":"refused"}"#);
    let cases: Vec<(&str, Vec<u8>, Exit)> = vec![
        ("an over-long line", too_long, Exit::Code(0)),
        ("too many problems", lines(&too_many), Exit::Code(0)),
        ("garbage", b"garbage\n".to_vec(), Exit::Code(0)),
        (
            "an unknown line",
            lines(&[r#"{"type":"run","argv":["sh"]}"#]),
            Exit::Code(0),
        ),
        ("no result", Vec::new(), Exit::Code(0)),
        ("a line after the result", lines(&[OK, OK]), Exit::Code(0)),
        ("a cut line", OK.as_bytes().to_vec(), Exit::Code(0)),
        ("a non-zero exit", lines(&[OK]), Exit::Code(1)),
        ("killed without a cancel", lines(&[OK]), Exit::Stopped),
        (
            "not started",
            Vec::new(),
            Exit::Lost("systemd-run is missing".into()),
        ),
        (
            "cancelled when nobody asked",
            lines(&[r#"{"type":"result","outcome":"cancelled"}"#]),
            Exit::Code(0),
        ),
        // RUY-829: on an "ok" result only the art step's problems are taken.
        (
            "a format problem on an ok result",
            lines(&[
                r#"{"type":"problem","code":"path.traversal","path":"payload/x","message":"m"}"#,
                OK,
            ]),
            Exit::Code(0),
        ),
        (
            "an importer code on an ok result",
            lines(&[
                r#"{"type":"problem","code":"staging.changed","path":"","message":"m"}"#,
                OK,
            ]),
            Exit::Code(0),
        ),
    ];
    for (what, out, exit) in cases {
        let (mut h, trust, installed) = scripted(out, exit, None);
        let r = h.install();
        assert_eq!(
            codes(&r),
            vec!["helper.failed".to_string()],
            "{what}: {:?}",
            r.problems
        );
        assert_refused(
            &h,
            &trust,
            &installed,
            &r,
            JobStatus::Failed,
            "helper.failed",
        );
    }
    // A forged "ok" over an empty job folder is the service's own refusal.
    let (mut h, trust, installed) = scripted(lines(&[OK]), Exit::Code(0), None);
    let r = h.install();
    assert_refused(
        &h,
        &trust,
        &installed,
        &r,
        JobStatus::Failed,
        "staging.changed",
    );
}

#[test]
fn a_helper_stopped_by_a_cancel_ends_cancelled() {
    let canceller: Arc<OnceLock<Canceller>> = Arc::default();
    let (mut h, trust, installed) =
        scripted(lines(&[]), Exit::Stopped, Some(Arc::clone(&canceller)));
    let _ = canceller.set(h.importer.canceller());
    let r = h.install();
    assert_eq!(r.status, JobStatus::Cancelled, "{:?}", r.problems);
    assert!(r.problems.is_empty());
    h.assert_nothing_left();
    assert_eq!(trust.inner.lock().unwrap().get(ID).unwrap(), None);
    assert_eq!(installed.inner.lock().unwrap().build_of(ID).unwrap(), None);
}

#[test]
fn inspect_fails_when_the_helper_breaks_its_contract() {
    let (h, _, _) = hostile(|real| {
        Box::new(Scripted {
            real,
            only_install: false,
            out: b"garbage\n".to_vec(),
            exit: Exit::Code(0),
            cancel: None,
        })
    });
    assert_eq!(
        h.importer.inspect(&pkg_path("game.play")).0,
        MethodStatus::Failed
    );
    assert_eq!(listing(&h.cfg.inspect), Vec::<String>::new());
    assert_eq!(h.staging(), Vec::<String>::new());
}

#[test]
fn a_package_that_changes_between_the_two_opens_is_refused() {
    let opens = Arc::new(AtomicU32::new(0));
    let genuine = Pkg::signed(&game());
    let mut other = game();
    other.manifest["name"] = json!({"en": "Other"});
    let other = Pkg::signed(&other);
    let shifting = Pkg::Custom(Arc::new(move || {
        let first = opens.fetch_add(1, Ordering::SeqCst) == 0;
        if first { genuine.open() } else { other.open() }.expect("the fixture opens")
    }));
    let (trust, installed) = (SharedTrust::default(), SharedInstalled::default());
    let mut setup = Setup::with(shifting);
    setup.stores = Some((trust.clone(), installed.clone()));
    let mut h = setup.build();
    let r = h.install();
    assert_refused(
        &h,
        &trust,
        &installed,
        &r,
        JobStatus::Failed,
        "source.changed",
    );
    assert_eq!(r.problems[0].path, "play.json");
}

#[test]
fn the_service_checks_the_build_before_the_helper_unpacks() {
    // build.not_newer comes from the service's own records: no install run of the helper.
    let installs = Arc::new(AtomicU32::new(0));
    let seen = Arc::clone(&installs);
    let mut setup = Setup::with(Pkg::signed(&game()));
    setup.installed = MemoryInstalled::new().with(ID, 1);
    setup.wrap_helper = Some(Box::new(move |real| {
        Box::new(Counting {
            real,
            installs: seen,
        })
    }));
    let mut h = setup.build();
    let r = h.install();
    assert_eq!(codes(&r), vec!["build.not_newer".to_string()]);
    assert_eq!(installs.load(Ordering::SeqCst), 0);
    h.assert_nothing_left();
}

struct Counting {
    real: Box<dyn Helper>,
    installs: Arc<AtomicU32>,
}

impl Helper for Counting {
    fn run(
        &self,
        request: &Request,
        cancel: &AtomicBool,
        on_output: &mut dyn FnMut(&[u8]) -> bool,
    ) -> Exit {
        if request.mode == Mode::Install {
            self.installs.fetch_add(1, Ordering::SeqCst);
        }
        self.real.run(request, cancel, on_output)
    }
}
