//! Fakes of the importer's side effects, for tests and the off-Linux development path.

use crate::core::deps::{
    Blocklists, Clock, Commit, CommitError, CommitRequest, FreeSpace, Hooks, OpenError, Opener,
    RecommitRequest, Step,
};
use crate::core::staging::{Dir, Kind};
use crate::core::status::Phase;
use crate::core::unpack;
use ruya_play_format::Source;
use ruya_play_trust::time::UnixSeconds;
use ruya_play_trust::Tier;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Mutex;

/// Opens packages through a function (a test builds a `MemorySource` or a zip in memory).
pub struct FnOpener<F>(pub F);

impl<F> Opener for FnOpener<F>
where
    F: Fn(&Path) -> Result<Box<dyn Source>, OpenError> + Send + Sync,
{
    fn open(&self, path: &Path) -> Result<Box<dyn Source + '_>, OpenError> {
        (self.0)(path)
    }
}

/// A fixed amount of free space, and the number of times it was asked.
#[derive(Debug, Default)]
pub struct FixedFreeSpace {
    /// Bytes free.
    pub bytes: AtomicU64,
    /// Calls so far.
    pub calls: AtomicU64,
}

impl FixedFreeSpace {
    /// `bytes` free.
    pub fn new(bytes: u64) -> Self {
        FixedFreeSpace {
            bytes: AtomicU64::new(bytes),
            calls: AtomicU64::new(0),
        }
    }
}

impl FreeSpace for FixedFreeSpace {
    fn available(&self, _dir: &Path) -> io::Result<u64> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(self.bytes.load(Ordering::SeqCst))
    }
}

/// Free space through a function (a test can look at the disk at the moment of the check).
pub struct FnFreeSpace<F>(pub F);

impl<F> FreeSpace for FnFreeSpace<F>
where
    F: Fn(&Path) -> io::Result<u64> + Send + Sync,
{
    fn available(&self, dir: &Path) -> io::Result<u64> {
        (self.0)(dir)
    }
}

/// A settable clock.
#[derive(Debug, Default)]
pub struct FixedClock(pub AtomicI64);

impl FixedClock {
    /// At `now`.
    pub fn at(now: UnixSeconds) -> Self {
        FixedClock(AtomicI64::new(now))
    }
}

impl Clock for FixedClock {
    fn now(&self) -> UnixSeconds {
        self.0.load(Ordering::SeqCst)
    }
}

/// A blocklist held in memory.
#[derive(Debug, Clone, Default)]
pub struct StaticBlocklists {
    /// The image's file (`None`: missing).
    pub image: Option<Vec<u8>>,
}

impl StaticBlocklists {
    /// A valid list with no entries.
    pub fn empty() -> Self {
        StaticBlocklists {
            image: Some(b"serial 1\n[packages]\n".to_vec()),
        }
    }

    /// A list with these `[packages]` lines.
    pub fn with(lines: &[&str]) -> Self {
        let mut text = String::from("serial 1\n[packages]\n");
        for l in lines {
            text.push_str(l);
            text.push('\n');
        }
        StaticBlocklists {
            image: Some(text.into_bytes()),
        }
    }
}

impl Blocklists for StaticBlocklists {
    fn image(&self) -> Option<Vec<u8>> {
        self.image.clone()
    }
    fn downloaded(&self) -> Option<(Vec<u8>, Vec<u8>)> {
        None
    }
}

/// One entry of a staged tree as the commit step saw it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeenEntry {
    /// Package path.
    pub path: String,
    /// Kind.
    pub kind: Kind,
    /// Permission bits (Unix), 0 elsewhere.
    pub mode: u32,
    /// Link target.
    pub target: Option<String>,
}

/// One call of [`RecordingCommit`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitCall {
    /// The job.
    pub job: String,
    /// The manifest id.
    pub id: String,
    /// The manifest build.
    pub build: u64,
    /// The tier.
    pub tier: Tier,
    /// The staged tree, walked without following links.
    pub tree: Vec<SeenEntry>,
    /// The names in `art/` (and its per-language folders), sorted.
    pub art: Vec<String>,
    /// The names in `meta/`, sorted.
    pub meta: Vec<String>,
}

/// One call of [`RecordingCommit::recommit`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecommitCall {
    /// The manifest id read back from the installed app.
    pub id: String,
    /// Its build.
    pub build: u64,
    /// The requests of its assessment, `key=value`.
    pub requests: Vec<String>,
    /// Everything in the copy of its `/app`, sorted.
    pub files: Vec<String>,
}

/// Runs inside [`RecordingCommit::commit`] (a test cancels or looks at the disk there).
pub type CommitHook = Box<dyn Fn(&CommitRequest<'_>) + Send + Sync>;

/// A commit that records its calls and copies the staged files into `target/<play.id>/` (folders
/// and regular files; links are recorded, not copied), so a test can see what was installed.
pub struct RecordingCommit {
    /// Every call.
    pub calls: Mutex<Vec<CommitCall>>,
    /// Where "installed" apps go (`None`: nowhere).
    pub target: Option<PathBuf>,
    /// The error the next call returns.
    pub fail: Mutex<Option<CommitError>>,
    /// Runs at the start of each call.
    pub hook: Option<CommitHook>,
    /// Every re-commit.
    pub recommits: Mutex<Vec<RecommitCall>>,
    /// The id of every uninstall.
    pub uninstalls: Mutex<Vec<String>>,
    /// The Flatpak installation (`app/play.<id>/current/active/files`) [`Commit::keep_previous`]
    /// copies the deployed `/app` from (`None`: it keeps nothing).
    pub installation: Option<PathBuf>,
    /// A re-commit replaces the deployed `/app` in [`Self::installation`] by its copy, as Flatpak's
    /// install would (a rollback test looks at what is deployed afterwards).
    pub deploy_recommits: bool,
    /// The repo: `<repo>/<id>/` is the `/app` of the kept build of `id` (`None`: nothing is kept).
    pub repo: Option<PathBuf>,
    /// Every repo call, `"<what> <id>"`: `keep`, `file`, `checkout`, `drop`.
    pub repo_calls: Mutex<Vec<String>>,
    /// The error the next [`Commit::keep_previous`] returns.
    pub fail_keep: Mutex<Option<CommitError>>,
    /// The repo no longer holds the deployed commit: [`Commit::keep_previous`] keeps nothing
    /// (`Ok(false)`) and drops what was kept.
    pub deployed_pruned: std::sync::atomic::AtomicBool,
}

impl RecordingCommit {
    /// Records calls; installs into `target` when given.
    pub fn new(target: Option<PathBuf>) -> Self {
        RecordingCommit {
            calls: Mutex::new(Vec::new()),
            target,
            fail: Mutex::new(None),
            hook: None,
            recommits: Mutex::new(Vec::new()),
            uninstalls: Mutex::new(Vec::new()),
            installation: None,
            deploy_recommits: false,
            repo: None,
            repo_calls: Mutex::new(Vec::new()),
            fail_keep: Mutex::new(None),
            deployed_pruned: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// The repo calls so far.
    pub fn repo_calls(&self) -> Vec<String> {
        self.repo_calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// The kept build's `/app` of `id`, when there is one.
    pub fn kept(&self, id: &str) -> Option<PathBuf> {
        let dir = self.repo.as_ref()?.join(id.to_ascii_lowercase());
        dir.is_dir().then_some(dir)
    }

    fn repo_call(&self, what: &str, id: &str) {
        self.repo_calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(format!("{what} {id}"));
    }

    fn deployed(&self, id: &str) -> Option<PathBuf> {
        let files = self
            .installation
            .as_ref()?
            .join("app")
            .join(format!("play.{id}"))
            .join("current/active/files");
        files.is_dir().then_some(files)
    }

    /// The ids uninstalled so far.
    pub fn uninstalls(&self) -> Vec<String> {
        self.uninstalls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// The calls so far.
    pub fn calls(&self) -> Vec<CommitCall> {
        self.calls.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The re-commits so far.
    pub fn recommits(&self) -> Vec<RecommitCall> {
        self.recommits
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

fn names_below(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut pending = vec![(dir.to_path_buf(), String::new())];
    while let Some((d, prefix)) = pending.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let name = format!("{prefix}{}", e.file_name().to_string_lossy());
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                pending.push((e.path(), format!("{name}/")));
            }
            out.push(name);
        }
    }
    out.sort();
    out
}

/// Copy the folder `from` to `to` (which must not exist): folders and regular files.
fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    std::fs::create_dir(to)?;
    for e in std::fs::read_dir(from)? {
        let e = e?;
        let target = to.join(e.file_name());
        if e.file_type()?.is_dir() {
            copy_dir(&e.path(), &target)?;
        } else {
            std::fs::copy(e.path(), target)?;
        }
    }
    Ok(())
}

fn replace_dir(from: &Path, to: &Path) -> io::Result<()> {
    if to.exists() {
        std::fs::remove_dir_all(to)?;
    }
    copy_dir(from, to)
}

impl Commit for RecordingCommit {
    fn commit(
        &self,
        request: &CommitRequest<'_>,
        progress: &mut dyn FnMut(Phase, f32),
    ) -> Result<(), CommitError> {
        if let Some(hook) = &self.hook {
            hook(request);
        }
        let io_fail = |e: io::Error| CommitError::Failed(e.to_string());
        let tree = Dir::open_root(request.tree).map_err(io_fail)?;
        let found = unpack::walk(&tree).map_err(io_fail)?;
        let call = CommitCall {
            job: request.job.to_string(),
            id: request.manifest.id.clone(),
            build: request.manifest.build,
            tier: request.tier,
            tree: found
                .iter()
                .map(|(p, f)| SeenEntry {
                    path: p.clone(),
                    kind: f.kind,
                    mode: f.mode,
                    target: f.target.clone(),
                })
                .collect(),
            art: names_below(request.art),
            meta: names_below(request.meta),
        };
        self.calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(call);
        progress(Phase::Committing, 0.5);
        if let Some(err) = self.fail.lock().unwrap_or_else(|e| e.into_inner()).take() {
            return Err(err);
        }
        if let Some(target) = &self.target {
            let app = target.join(format!("play.{}", request.manifest.id));
            std::fs::create_dir_all(&app).map_err(io_fail)?;
            for (p, f) in &found {
                let mut to = app.clone();
                let mut from = request.tree.to_path_buf();
                for c in p.split('/') {
                    to.push(c);
                    from.push(c);
                }
                match f.kind {
                    Kind::Dir => std::fs::create_dir_all(&to).map_err(io_fail)?,
                    Kind::File => {
                        std::fs::copy(&from, &to).map_err(io_fail)?;
                    }
                    _ => {}
                }
            }
        }
        progress(Phase::Installing, 1.0);
        Ok(())
    }

    /// Records the call; the error of [`Self::fail`] is returned after it.
    fn recommit(&self, request: &RecommitRequest<'_>) -> Result<(), CommitError> {
        let call = RecommitCall {
            id: request.manifest.id.clone(),
            build: request.manifest.build,
            requests: request
                .assessment
                .requests
                .iter()
                .map(|r| format!("{}={}", r.key, r.value))
                .collect(),
            files: names_below(request.files),
        };
        self.recommits
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(call);
        if let Some(err) = self.fail.lock().unwrap_or_else(|e| e.into_inner()).take() {
            return Err(err);
        }
        if self.deploy_recommits {
            let files = self
                .deployed(&request.manifest.id)
                .ok_or_else(|| CommitError::Failed("nothing is deployed to replace".into()))?;
            replace_dir(request.files, &files).map_err(|e| CommitError::Failed(e.to_string()))?;
        }
        Ok(())
    }

    /// Records the id; the error of [`Self::fail`] is returned after it. With a `target`, the
    /// installed copy of the app goes.
    fn uninstall(&self, id: &str) -> Result<(), CommitError> {
        self.uninstalls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(id.to_string());
        if let Some(err) = self.fail.lock().unwrap_or_else(|e| e.into_inner()).take() {
            return Err(err);
        }
        if let Some(target) = &self.target {
            let _ = std::fs::remove_dir_all(target.join(format!("play.{id}")));
        }
        if let Some(kept) = self.kept(id) {
            let _ = std::fs::remove_dir_all(kept);
        }
        Ok(())
    }

    /// Records the call; with an installation and a repo, the deployed `/app` is copied to
    /// `<repo>/<id>`. The error of [`Self::fail_keep`] is returned first; with
    /// [`Self::deployed_pruned`] nothing is kept and the kept build goes.
    fn keep_previous(&self, id: &str) -> Result<bool, CommitError> {
        self.repo_call("keep", id);
        if let Some(err) = self
            .fail_keep
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            return Err(err);
        }
        if self
            .deployed_pruned
            .load(std::sync::atomic::Ordering::SeqCst)
        {
            if let Some(kept) = self.kept(id) {
                let _ = std::fs::remove_dir_all(kept);
            }
            return Ok(false);
        }
        let Some(repo) = &self.repo else {
            return Ok(true);
        };
        let files = self
            .deployed(id)
            .ok_or_else(|| CommitError::Failed("flatpak info named no commit".into()))?;
        let kept = repo.join(id.to_ascii_lowercase());
        std::fs::create_dir_all(repo)
            .and_then(|()| replace_dir(&files, &kept))
            .map_err(|e| CommitError::Failed(e.to_string()))?;
        // Flatpak writes `.ref` when it deploys; the commit in the repo has none.
        let _ = std::fs::remove_file(kept.join(".ref"));
        Ok(true)
    }

    fn previous_file(&self, id: &str, name: &str) -> Result<Vec<u8>, CommitError> {
        self.repo_call("file", id);
        let kept = self
            .kept(id)
            .ok_or_else(|| CommitError::Failed("no previous ref".into()))?;
        std::fs::read(kept.join(name)).map_err(|e| CommitError::Failed(e.to_string()))
    }

    fn check_out_previous(&self, id: &str, dest: &Path) -> Result<(), CommitError> {
        self.repo_call("checkout", id);
        let kept = self
            .kept(id)
            .ok_or_else(|| CommitError::Failed("no previous ref".into()))?;
        copy_dir(&kept, dest).map_err(|e| CommitError::Failed(e.to_string()))
    }

    fn drop_previous(&self, id: &str) -> Result<(), CommitError> {
        self.repo_call("drop", id);
        if let Some(kept) = self.kept(id) {
            std::fs::remove_dir_all(kept).map_err(|e| CommitError::Failed(e.to_string()))?;
        }
        Ok(())
    }
}

/// Hooks through a function.
pub struct FnHooks<F>(pub F);

impl<F> Hooks for FnHooks<F>
where
    F: Fn(&str, &Step<'_>) + Send + Sync,
{
    fn step(&self, job: &str, step: &Step<'_>) {
        (self.0)(job, step)
    }
}
