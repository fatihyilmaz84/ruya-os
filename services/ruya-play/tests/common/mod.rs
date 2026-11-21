//! The test harness: an importer over temporary folders with fakes, packages built with the
//! format crate's fixture builder (`Fx`), signing, real art, and directory snapshots.
#![allow(dead_code)]

#[path = "../../../ruya-play-format/tests/common/mod.rs"]
pub mod fx;

#[allow(unused_imports)]
pub use fx::{sha_hex, write_zip, Fx, ZE};

use ruya_play::core::deps::{ArtVetter, NoHooks, RuyaPlayArt};
use ruya_play::core::fakes::{
    CommitHook, FixedClock, FixedFreeSpace, FnOpener, RecordingCommit, StaticBlocklists,
};
use ruya_play::core::installed::{Installed, MemoryInstalled};
use ruya_play::service::commit::Runner;
use ruya_play::{
    Config, Deps, Event, FreeSpace, Helper, HelperDeps, Hooks, Importer, InProcessHelper,
    JobResult, MethodStatus,
};
use ruya_play::{OpenError, Phase};
use ruya_play_art::{Outcome, Slot, SlotResult};
use ruya_play_format::{Entry, EntryKind, FolderSource, MemorySource, Problem, Source, ZipSource};
use ruya_play_trust::{
    countersign, sign_package, MemoryTrustStore, SecretKey, StoreKeys, TrustStore,
};
use std::collections::BTreeMap;
use std::io::{self, Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// The clock every harness starts at (2026-11-17).
pub const NOW: i64 = 1_794_873_600;

/// The developer key of the tests (the published test seed of 05 §9.2, worth nothing).
pub fn dev_key() -> SecretKey {
    let seed: [u8; 32] = std::array::from_fn(|i| i as u8);
    SecretKey::from_seed(&seed)
}

/// Another developer.
pub fn other_key() -> SecretKey {
    SecretKey::from_seed(&[0x77; 32])
}

/// The store key of the tests.
pub fn store_key() -> SecretKey {
    let seed: [u8; 32] = std::array::from_fn(|i| 0x20 + i as u8);
    SecretKey::from_seed(&seed)
}

/// A PNG of `w` x `h` (real art for the art step).
pub fn png(w: u32, h: u32) -> Vec<u8> {
    let img = image::RgbaImage::from_pixel(w, h, image::Rgba([200, 60, 20, 255]));
    let mut out = Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png).unwrap();
    out.into_inner()
}

/// Bytes of a payload file of `n` bytes that is not all one value.
pub fn payload(n: usize) -> Vec<u8> {
    (0..n).map(|i| (i % 251) as u8).collect()
}

/// A small game with real art: a 512 px icon, a 1 MiB payload file (several chunks) and a script.
pub fn game() -> Fx {
    let mut fx = Fx::minimal();
    fx.files = vec![
        ("art/icon.png".into(), png(512, 512)),
        ("payload/data.bin".into(), payload(1024 * 1024 + 17)),
        ("payload/game".into(), b"#!/bin/sh\necho hi\n".to_vec()),
    ];
    fx
}

/// Root files added to a source (signatures), the rest passed through.
pub struct Overlay {
    pub inner: Box<dyn Source>,
    pub extra: Vec<(String, Vec<u8>)>,
}

impl Source for Overlay {
    fn entries(&self) -> Result<Vec<Entry>, Vec<Problem>> {
        let mut v = self.inner.entries()?;
        for (p, d) in &self.extra {
            v.push(Entry {
                path: p.clone(),
                kind: EntryKind::File,
                size: d.len() as u64,
            });
        }
        Ok(v)
    }
    fn open(&self, path: &str) -> io::Result<Box<dyn Read + '_>> {
        match self.extra.iter().find(|(p, _)| p == path) {
            Some((_, d)) => Ok(Box::new(Cursor::new(d.clone()))),
            None => self.inner.open(path),
        }
    }
}

fn read_root(src: &dyn Source, name: &str) -> Option<Vec<u8>> {
    let listed = src
        .entries()
        .ok()?
        .into_iter()
        .any(|e| e.path == name && e.kind == EntryKind::File);
    if !listed {
        return None;
    }
    let mut v = Vec::new();
    src.open(name)
        .ok()?
        .take(64 << 20)
        .read_to_end(&mut v)
        .ok()?;
    Some(v)
}

/// `inner` with a `play.sig` by `key` (and a `store.sig` by `store`), when its `play.json` names an
/// ASCII id and a build, as a signer would; otherwise `inner` unchanged. (`sign_package` also
/// signs a non-ASCII id, which `verify_signatures` then refuses as `sig.malformed`.)
pub fn signed(
    inner: Box<dyn Source>,
    key: &SecretKey,
    store: Option<&SecretKey>,
) -> Box<dyn Source> {
    let (Some(json), Some(files)) = (
        read_root(&*inner, "play.json"),
        read_root(&*inner, "play.files"),
    ) else {
        return inner;
    };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&json) else {
        return inner;
    };
    let (Some(id), Some(build)) = (v["id"].as_str(), v["build"].as_u64()) else {
        return inner;
    };
    if !id.is_ascii() {
        return inner;
    }
    let Ok(sig) = sign_package(key, id, build, &json, &files, NOW, &[]) else {
        return inner;
    };
    let mut extra = vec![("play.sig".to_string(), sig.clone())];
    if let Some(store) = store {
        extra.push(("store.sig".into(), countersign(store, id, build, &sig, NOW)));
    }
    Box::new(Overlay { inner, extra })
}

/// How a test package is held.
#[derive(Clone)]
pub enum Pkg {
    /// In memory.
    Mem(MemorySource),
    /// A zip in memory.
    Zip(Vec<u8>),
    /// A folder on disk.
    Folder(PathBuf),
    /// Signed by the key (and countersigned by the store key) whenever it is opened.
    Signed(Box<Pkg>, Arc<SecretKey>, Option<Arc<SecretKey>>),
    /// Any source, made fresh for each open.
    Custom(Arc<dyn Fn() -> Box<dyn Source> + Send + Sync>),
}

impl Pkg {
    /// `fx` in memory, signed by [`dev_key`].
    pub fn signed(fx: &Fx) -> Pkg {
        Pkg::Signed(Box::new(Pkg::Mem(fx.mem())), Arc::new(dev_key()), None)
    }

    /// Open it.
    pub fn open(&self) -> Result<Box<dyn Source>, OpenError> {
        match self {
            Pkg::Mem(m) => Ok(Box::new(m.clone())),
            Pkg::Zip(bytes) => ZipSource::new(Cursor::new(bytes.clone()))
                .map(|z| Box::new(z) as Box<dyn Source>)
                .map_err(OpenError::Problems),
            Pkg::Folder(p) => Ok(Box::new(FolderSource::new(p))),
            Pkg::Signed(inner, key, store) => Ok(signed(inner.open()?, key, store.as_deref())),
            Pkg::Custom(make) => Ok(make()),
        }
    }
}

/// An art step that passes every slot without reading it (the format crate's fixtures carry
/// placeholder bytes, not images; `ruya-play-art`'s own suite vets real art).
pub struct PassArt;

impl ArtVetter for PassArt {
    fn vet(&self, inputs: &[(Slot, PathBuf)], _out_dir: &Path) -> Vec<SlotResult> {
        inputs
            .iter()
            .map(|(slot, _)| SlotResult {
                slot: *slot,
                outcome: Outcome::Ok { files: Vec::new() },
            })
            .collect()
    }
}

/// What a harness is built from.
pub struct Setup {
    pub packages: Vec<(PathBuf, Pkg)>,
    pub free: u64,
    pub free_space: Option<Box<dyn FreeSpace>>,
    pub blocklist: StaticBlocklists,
    pub trust: MemoryTrustStore,
    pub developer_mode: bool,
    pub installed: MemoryInstalled,
    pub store_keys: StoreKeys,
    pub art: Box<dyn ArtVetter>,
    pub hooks: Box<dyn Hooks>,
    pub commit_hook: Option<CommitHook>,
    /// The clock at start.
    pub now: i64,
    /// Replaces `trust` and `installed` (stores a test shares or makes fail).
    pub stores: Option<(SharedTrust, SharedInstalled)>,
    /// Wraps the in-process helper (a test that plays a hostile helper).
    pub wrap_helper: Option<HelperWrap>,
}

/// Turns the harness's in-process helper into the helper the importer gets.
pub type HelperWrap = Box<dyn FnOnce(Box<dyn Helper>) -> Box<dyn Helper>>;

impl Default for Setup {
    fn default() -> Self {
        Setup {
            packages: Vec::new(),
            free: u64::MAX,
            free_space: None,
            blocklist: StaticBlocklists::empty(),
            trust: MemoryTrustStore::new(),
            developer_mode: false,
            installed: MemoryInstalled::new(),
            store_keys: StoreKeys::new(vec![store_key().public()]),
            art: Box::new(RuyaPlayArt),
            hooks: Box::new(NoHooks),
            commit_hook: None,
            now: NOW,
            stores: None,
            wrap_helper: None,
        }
    }
}

/// The path tests give a package.
pub fn pkg_path(name: &str) -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(format!("C:\\media\\usb\\{name}"))
    } else {
        PathBuf::from(format!("/run/media/usb/{name}"))
    }
}

impl Setup {
    /// One package at [`pkg_path`]`("game.play")`.
    pub fn with(pkg: Pkg) -> Setup {
        Setup {
            packages: vec![(pkg_path("game.play"), pkg)],
            ..Setup::default()
        }
    }

    /// Build the harness in fresh temporary folders.
    pub fn build(self) -> Harness {
        let root = tempfile::tempdir().unwrap();
        Harness::open_in(root, self)
    }
}

/// An importer over temporary folders, and handles on its fakes.
pub struct Harness {
    pub root: tempfile::TempDir,
    pub cfg: Config,
    pub target: PathBuf,
    pub outside: PathBuf,
    pub importer: Importer,
    pub commit: Arc<RecordingCommit>,
    pub free: Arc<FixedFreeSpace>,
    pub clock: Arc<FixedClock>,
    pub events: Vec<Event>,
}

impl Harness {
    /// An importer over `root` (which may hold a previous run's folders).
    pub fn open_in(root: tempfile::TempDir, setup: Setup) -> Harness {
        let cfg = Config::under(root.path());
        let target = root.path().join("target");
        let outside = root.path().join("outside");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let mut commit = RecordingCommit::new(Some(target.clone()));
        commit.hook = setup.commit_hook;
        let commit = Arc::new(commit);
        let free = Arc::new(FixedFreeSpace::new(setup.free));
        let clock = Arc::new(FixedClock::at(setup.now));
        let packages: BTreeMap<PathBuf, Pkg> = setup.packages.into_iter().collect();
        let opener = FnOpener(move |p: &Path| match packages.get(p) {
            Some(pkg) => pkg.open(),
            None => Err(OpenError::Missing),
        });
        let (mut trust, installed): (
            Box<dyn TrustStore + Send>,
            Box<dyn ruya_play::InstalledBuilds + Send>,
        ) = match setup.stores {
            Some((t, i)) => (Box::new(t), Box::new(i)),
            None => (Box::new(setup.trust), Box::new(setup.installed)),
        };
        trust.set_developer_mode(setup.developer_mode).unwrap();
        let free_space: Box<dyn FreeSpace> = match setup.free_space {
            Some(f) => f,
            None => Box::new(Arc::clone(&free)),
        };
        // The hooks see the helper's steps (staging, chunks, art) and the service's (before the
        // unpack, the commit).
        let hooks: Arc<dyn Hooks> = Arc::from(setup.hooks);
        let helper: Box<dyn Helper> = Box::new(InProcessHelper::new(HelperDeps {
            opener: Box::new(opener),
            art: setup.art,
            store_keys: setup.store_keys.clone(),
            hooks: Box::new(Arc::clone(&hooks)),
        }));
        let helper = match setup.wrap_helper {
            Some(wrap) => wrap(helper),
            None => helper,
        };
        let deps = Deps {
            helper,
            free_space,
            commit: Box::new(Arc::clone(&commit)),
            clock: Box::new(Arc::clone(&clock)),
            blocklists: Box::new(setup.blocklist),
            store_keys: setup.store_keys,
            trust,
            installed,
            hooks: Box::new(hooks),
        };
        let importer = Importer::open(cfg.clone(), deps).expect("the importer opens");
        Harness {
            root,
            cfg,
            target,
            outside,
            importer,
            commit,
            free,
            clock,
            events: Vec::new(),
        }
    }

    /// Queue `path` (as an admin) and run it to its end.
    pub fn install_at(&mut self, path: &Path) -> JobResult {
        let (status, job) = self.importer.queue_install(path, true);
        assert_eq!(status, MethodStatus::Ok, "queue {}", path.display());
        let mut events = Vec::new();
        let result = self
            .importer
            .run_next(&mut |e| events.push(e))
            .expect("a job ran");
        assert_eq!(result.job, job);
        self.events.extend(events);
        result
    }

    /// Install the one package of [`Setup::with`].
    pub fn install(&mut self) -> JobResult {
        self.install_at(&pkg_path("game.play"))
    }

    /// Everything below the staging root.
    pub fn staging(&self) -> Vec<String> {
        listing(&self.cfg.staging)
    }

    /// Everything below the fake commit's target.
    pub fn installed_files(&self) -> Vec<String> {
        listing(&self.target)
    }

    /// Assert that a refused job left nothing: no staging directory, nothing installed, and the
    /// commit step never ran.
    #[track_caller]
    pub fn assert_nothing_left(&self) {
        assert_eq!(self.staging(), Vec::<String>::new(), "staging is not empty");
        assert_eq!(
            self.installed_files(),
            Vec::<String>::new(),
            "something was installed"
        );
        assert!(self.commit.calls().is_empty(), "the commit step ran");
    }

    /// The progress events of the run, checked: the percent never decreases and the phase never
    /// goes back; exactly one Finished, last.
    #[track_caller]
    pub fn assert_events_ordered(&self) {
        let mut last = (Phase::None, 0u32);
        let mut finished = 0;
        for (i, e) in self.events.iter().enumerate() {
            match e {
                Event::Progress { percent, phase, .. } => {
                    assert!(finished == 0, "progress after Finished");
                    assert!(
                        *phase >= last.0,
                        "phase went back at event {i}: {:?}",
                        self.events
                    );
                    assert!(
                        *percent >= last.1,
                        "percent went down at event {i}: {:?}",
                        self.events
                    );
                    last = (*phase, *percent);
                }
                Event::Finished { .. } => finished += 1,
            }
        }
        assert_eq!(finished, 1, "{:?}", self.events);
        assert!(matches!(self.events.last(), Some(Event::Finished { .. })));
    }
}

/// Every path below `dir`, sorted, read without following links (`name -> target` for a link).
/// The `deploy` file Flatpak writes next to `files/` (RUY-863): a GVariant `(ssasta{sv})`, of
/// which the origin is the first, NUL-terminated string. The rest is filler, as in a real one.
pub fn write_deploy(installation: &Path, id: &str, origin: &str) {
    let active = installation
        .join("app")
        .join(format!("play.{id}"))
        .join("current")
        .join("active");
    std::fs::create_dir_all(&active).unwrap();
    let mut bytes = origin.as_bytes().to_vec();
    bytes.push(0);
    bytes.extend_from_slice(b"0123456789abcdef\0\0\0\0\0\0\0\0");
    std::fs::write(active.join("deploy"), bytes).unwrap();
}

pub fn listing(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut pending = vec![(dir.to_path_buf(), String::new())];
    while let Some((d, prefix)) = pending.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let name = format!("{prefix}{}", e.file_name().to_string_lossy());
            let meta = std::fs::symlink_metadata(e.path()).unwrap();
            if meta.file_type().is_symlink() {
                let t = std::fs::read_link(e.path()).unwrap();
                out.push(format!("{name} -> {}", t.display()));
            } else {
                if meta.is_dir() {
                    pending.push((e.path(), format!("{name}/")));
                }
                out.push(name);
            }
        }
    }
    out.sort();
    out
}

/// The codes of a result's problems.
pub fn codes(r: &JobResult) -> Vec<String> {
    r.problems.iter().map(|p| p.code.clone()).collect()
}

/// Which writes of the shared stores fail.
#[derive(Clone, Default)]
pub struct Faults {
    pub put: Arc<std::sync::atomic::AtomicBool>,
    pub remove: Arc<std::sync::atomic::AtomicBool>,
    pub record: Arc<std::sync::atomic::AtomicBool>,
    pub forget: Arc<std::sync::atomic::AtomicBool>,
}

fn on(flag: &std::sync::atomic::AtomicBool) -> bool {
    flag.load(std::sync::atomic::Ordering::SeqCst)
}

/// A trust store the test can look into, whose writes can be made to fail.
#[derive(Clone, Default)]
pub struct SharedTrust {
    pub inner: Arc<std::sync::Mutex<MemoryTrustStore>>,
    pub faults: Faults,
}

fn trust_io() -> ruya_play_trust::TrustError {
    ruya_play_trust::TrustError::StateIo {
        detail: "the disk is full".into(),
    }
}

impl TrustStore for SharedTrust {
    fn get(
        &self,
        id: &str,
    ) -> Result<Option<ruya_play_trust::IdRecord>, ruya_play_trust::TrustError> {
        self.inner.lock().unwrap().get(id)
    }
    fn put(
        &mut self,
        record: ruya_play_trust::IdRecord,
    ) -> Result<(), ruya_play_trust::TrustError> {
        if on(&self.faults.put) {
            return Err(trust_io());
        }
        self.inner.lock().unwrap().put(record)
    }
    fn remove(&mut self, id: &str) -> Result<bool, ruya_play_trust::TrustError> {
        if on(&self.faults.remove) {
            return Err(trust_io());
        }
        self.inner.lock().unwrap().remove(id)
    }
    fn developer_mode(&self) -> Result<bool, ruya_play_trust::TrustError> {
        self.inner.lock().unwrap().developer_mode()
    }
    fn set_developer_mode(&mut self, on: bool) -> Result<(), ruya_play_trust::TrustError> {
        self.inner.lock().unwrap().set_developer_mode(on)
    }
}

/// Installed builds the test can look into, whose writes can be made to fail.
#[derive(Clone, Default)]
pub struct SharedInstalled {
    pub inner: Arc<std::sync::Mutex<MemoryInstalled>>,
    pub faults: Faults,
}

fn installed_io() -> Problem {
    Problem::new("installed.io", "installed.json", "the disk is full")
}

impl ruya_play::InstalledBuilds for SharedInstalled {
    fn get(&self, id: &str) -> Result<Option<Installed>, Problem> {
        self.inner.lock().unwrap().get(id)
    }
    fn record(&mut self, id: &str, build: u64) -> Result<(), Problem> {
        if on(&self.faults.record) {
            return Err(installed_io());
        }
        self.inner.lock().unwrap().record(id, build)
    }
    fn stamp(&mut self, id: &str, generation: u32) -> Result<(), Problem> {
        if on(&self.faults.record) {
            return Err(installed_io());
        }
        self.inner.lock().unwrap().stamp(id, generation)
    }
    fn forget(&mut self, id: &str) -> Result<(), Problem> {
        if on(&self.faults.forget) {
            return Err(installed_io());
        }
        self.inner.lock().unwrap().forget(id)
    }
    fn all(&self) -> Result<std::collections::BTreeMap<String, Installed>, Problem> {
        self.inner.lock().unwrap().all()
    }
}

/// The fingerprint [`FakeRunner`]'s GPG answers with.
pub const FPR: &str = "0123456789ABCDEF0123456789ABCDEF01234567";

/// Runs nothing: records each command line, answers gpg like a fresh GPG home, writes the
/// exported key, and keeps the listing and the `metadata` of the build folder `build-finish`
/// gets.
#[derive(Default)]
pub struct FakeRunner {
    pub calls: std::sync::Mutex<Vec<Vec<String>>>,
    pub generated: std::sync::atomic::AtomicBool,
    pub layout: std::sync::Mutex<Vec<String>>,
    pub metadata: std::sync::Mutex<String>,
    /// What `flatpak list --runtime` answers (the installed runtimes, one ref per line).
    pub runtimes: std::sync::Mutex<String>,
    /// A command with this argument fails (the network is gone: a command naming Flathub).
    pub fail_with_arg: std::sync::Mutex<Option<String>>,
}

impl Runner for FakeRunner {
    fn run(&self, argv: &[String]) -> Result<String, String> {
        use std::sync::atomic::Ordering;
        self.calls.lock().unwrap().push(argv.to_vec());
        let has = |a: &str| argv.iter().any(|x| x == a);
        if let Some(arg) = self.fail_with_arg.lock().unwrap().as_deref() {
            if has(arg) {
                return Err(format!("{} failed: no network", argv[1]));
            }
        }
        if argv[0] == "flatpak" && argv.get(1).map(String::as_str) == Some("list") {
            return Ok(self.runtimes.lock().unwrap().clone());
        }
        if argv[0] == "gpg" && has("--list-secret-keys") {
            if self.generated.load(Ordering::SeqCst) {
                return Ok(format!(
                    "sec:u:255:22:X:1::::::scESC:\nfpr:::::::::{FPR}:\n"
                ));
            }
            return Ok(String::new());
        }
        if argv[0] == "gpg" && has("--quick-gen-key") {
            self.generated.store(true, Ordering::SeqCst);
        }
        if argv[0] == "gpg" && has("--export") {
            let out = argv.iter().position(|a| a == "--output").unwrap() + 1;
            std::fs::write(&argv[out], b"public key").unwrap();
        }
        if argv[0] == "ostree" {
            let repo = argv[2].strip_prefix("--repo=").unwrap();
            std::fs::create_dir_all(repo).unwrap();
            std::fs::write(Path::new(repo).join("config"), b"[core]\n").unwrap();
        }
        if argv.get(1).map(String::as_str) == Some("build-finish") {
            let app = Path::new(&argv[2]);
            *self.layout.lock().unwrap() = listing(app);
            *self.metadata.lock().unwrap() =
                std::fs::read_to_string(app.join("metadata")).unwrap_or_default();
        }
        Ok(String::new())
    }
}

/// The deployed `/app` folder of `play.<id>` in the harness's Flatpak installation.
pub fn files_dir(h: &Harness, id: &str) -> PathBuf {
    h.cfg
        .flatpak
        .join("app")
        .join(format!("play.{id}"))
        .join("current")
        .join("active")
        .join("files")
}

/// Set the permission bits of `path` (Unix; nothing elsewhere).
#[cfg(unix)]
pub fn mode(path: &Path, bits: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(bits)).unwrap();
}

/// Set the permission bits of `path` (Unix; nothing elsewhere).
#[cfg(not(unix))]
pub fn mode(_path: &Path, _bits: u32) {}

/// The deployment of the unsigned `fx` as the commit lays it out: the tree with the modes of
/// `play.files`, the root files, and what the console adds (the mount folder of each of its
/// runner's extension points, the desktop entry, the art, the trust record), with Flatpak's empty
/// `.ref`.
pub fn deploy(h: &Harness, id: &str, fx: &Fx) -> PathBuf {
    let files = files_dir(h, id);
    std::fs::create_dir_all(&files).unwrap();
    write_deploy(&h.cfg.flatpak, id, ruya_play_art::PLAY_REMOTE);
    for (p, d) in &fx.files {
        let full = files.join(p);
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(&full, d).unwrap();
        mode(&full, if fx.exec.contains(p) { 0o755 } else { 0o644 });
    }
    for d in &fx.dirs {
        std::fs::create_dir_all(files.join(d)).unwrap();
    }
    std::fs::write(files.join("play.files"), fx.table()).unwrap();
    std::fs::write(files.join("play.json"), fx.manifest_bytes()).unwrap();
    std::fs::write(files.join(".ref"), b"").unwrap();
    let runner = fx.manifest["run"]["runner"].as_str().unwrap_or("native");
    for point in ruya_play::service::commit::extension_points(runner) {
        std::fs::create_dir_all(files.join(point.directory)).unwrap();
    }
    std::fs::create_dir_all(files.join("share/applications")).unwrap();
    std::fs::write(
        files.join(format!("share/applications/play.{id}.desktop")),
        b"[Desktop Entry]\n",
    )
    .unwrap();
    std::fs::create_dir_all(files.join("share/ruyaos/play/art")).unwrap();
    std::fs::write(files.join("share/ruyaos/play/art/icon.png"), b"art").unwrap();
    std::fs::write(
        files.join(ruya_play::service::commit::TRUST_RECORD_IN_APP),
        br#"{"format":1,"tier":"unverified","signer_id":null,"signer_name":null,"store_signed":false}"#,
    )
    .unwrap();
    // Every folder is 0755 (Unix), as the commit's canonical modes make them.
    for e in listing(&files) {
        let p = files.join(&e);
        if !e.contains(" -> ") && p.is_dir() {
            mode(&p, 0o755);
        }
    }
    mode(&files, 0o755);
    // Flatpak's `metadata` beside `files/`, generated as the commit does from what the app asks.
    let (manifest, assessment) = ruya_play::core::reconcile::installed_app(
        &ruya_play::core::staging::Dir::open_root(&files).unwrap(),
    )
    .unwrap();
    std::fs::write(
        files.parent().unwrap().join("metadata"),
        ruya_play::service::commit::metadata(&manifest, &assessment),
    )
    .unwrap();
    files
}

/// `game()` with its manifest asking for `perms` as build `build`.
pub fn asking(perms: serde_json::Value, build: u64) -> Fx {
    let mut fx = game();
    fx.manifest["permissions"] = perms;
    fx.manifest["build"] = serde_json::json!(build);
    fx
}

/// The installed app of `game()`'s id, build 1, asking for `perms` in its own `play.json`.
pub fn installed_with(perms: serde_json::Value, new: Fx) -> Harness {
    let setup = Setup {
        installed: ruya_play::core::installed::MemoryInstalled::new().with("com.example.mini", 1),
        ..Setup::with(Pkg::signed(&new))
    };
    let h = setup.build();
    let files = ruya_play::core::reconcile::deployment_files(&h.cfg.flatpak, "com.example.mini");
    std::fs::create_dir_all(&files).unwrap();
    write_deploy(
        &h.cfg.flatpak,
        "com.example.mini",
        ruya_play_art::PLAY_REMOTE,
    );
    let play_json = serde_json::json!({"format": 1, "id": "com.example.mini", "build": 1, "permissions": perms});
    std::fs::write(files.join("play.json"), play_json.to_string()).unwrap();
    h
}
