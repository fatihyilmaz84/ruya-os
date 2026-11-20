//! The Flatpak commit (05 §7.1, RUY-829): a verified staged tree becomes the system Flatpak app
//! `play.<id>`.
//!
//! In the job's staging folder the commit lays out a Flatpak build directory `app/` (the package
//! tree is renamed to `app/files`, the verified root files are copied next to it, the vetted art
//! goes to `app/files/share/ruyaos/play/art/`, every extension point's mount folder and the app's
//! own `share/applications/play.<id>.desktop` and the trust record `share/ruyaos/play/trust.json`
//! are written, and `app/metadata` is generated from the manifest and its assessment), makes root
//! the owner of everything with the modes of `play.files` (files 0644 or 0755, folders 0755), then
//! runs:
//!
//! 1. `flatpak build-finish` (exports the desktop entry),
//! 2. `flatpak build-export` into a `bare-user-only` OSTree repo on `/var` (the reflink rule of
//!    §7.1), signed with the **device key**: a GPG key generated on first use under
//!    `/var/lib/ruya-play/gnupg` (root, 0700; never in the image),
//! 3. `flatpak install --or-update --system` from the local remote [`REMOTE`], which was added with
//!    that key, so Flatpak checks the signature as for any remote (never `--no-gpg-verify`).
//!
//! A **re-commit** (ADR-038, RUY-900: the start-up reconcile found an app whose
//! [`METADATA_GENERATION`] is older) takes a copy of the deployed `/app` instead of a staged
//! package ([`lay_out_installed`]): the generated parts are written again over it and the same
//! three steps follow.
//!
//! The command lines are pure functions with host tests; [`FlatpakCommit`] runs them through a
//! [`Runner`] (the real one on Linux; a recording one in the tests).

use crate::core::deps::{Commit, CommitError, CommitRequest, RecommitRequest};
use crate::core::status::Phase;
use ruya_play_format::limits::{windows_runner, I386_LIB_DIR, ROOT_FILES};
use ruya_play_format::manifest::Manifest;
use ruya_play_format::table::RESERVED_TOP_LEVEL;
use ruya_play_trust::{grants, metadata_sections, Assessment, Gate, TrustRecord};
use std::path::{Path, PathBuf};

/// The system remote the importer installs from.
pub const REMOTE: &str = ruya_play_art::PLAY_REMOTE;
/// The branch every imported app is committed on.
pub const BRANCH: &str = "stable";
/// The architecture (05 §6: x86_64 only).
pub const ARCH: &str = "x86_64";
/// The runtime of every imported app (the Play platform, 05 §6.4).
pub const RUNTIME: &str = "org.freedesktop.Platform";
/// Its branch (the runtime of the developer guide's samples; the spike used 25.08).
pub const RUNTIME_BRANCH: &str = "26.08";
/// The generation of the generated metadata and desktop entry ([`metadata`], [`desktop_entry`]).
/// Raise it with every change of either that installed apps need: the importer stamps it into
/// `installed.json` after each commit, and the start-up reconcile commits every app of ours whose
/// recorded generation is older again (ADR-038). 0 is an app recorded before generations; 1 adds
/// the runner and 32-bit extension points.
pub const METADATA_GENERATION: u32 = 1;
/// The branch of the console's own extension points: their ABI (ADR-038).
pub const PLAY_EXTENSION_BRANCH: &str = "1";
/// The launcher extension (05 §6.4).
pub const LAUNCHER_EXTENSION: &str = "org.ruyaos.Play.Launcher";
/// Its mount folder in `/app`.
pub const LAUNCHER_DIR: &str = "launcher";
/// The launcher's command inside the sandbox (in [`LAUNCHER_DIR`]).
pub const LAUNCH_COMMAND: &str = "/app/launcher/bin/ruya-play-launch";
/// The point every system runner `org.ruyaos.Play.Runner.<Name>` mounts under, one subfolder each
/// (ADR-038, 05 §6.4).
pub const RUNNER_EXTENSION: &str = "org.ruyaos.Play.Runner";
/// Its mount folder in `/app`.
pub const RUNNER_DIR: &str = "runners";
/// The freedesktop runtime's 32-bit libraries, for Windows runners (05 §16 Q3).
pub const COMPAT_I386_EXTENSION: &str = "org.freedesktop.Platform.Compat.i386";
/// Its mount folder in `/app`.
pub const COMPAT_I386_DIR: &str = I386_LIB_DIR;
/// The 32-bit GL drivers, for Windows runners.
pub const GL32_EXTENSION: &str = "org.freedesktop.Platform.GL32";
/// Its mount folder in `/app` (inside the Compat.i386 mount).
pub const GL32_DIR: &str = "lib/i386-linux-gnu/GL";
/// The GL32 branch the GL drivers carry besides the runtime's branch.
pub const GL32_BRANCH: &str = "1.4";
/// The folders of the GL32 extensions merged into one (as the freedesktop runtime declares it;
/// `scripts/spikes/play/q3-proton.sh`).
pub const GL32_MERGE_DIRS: &str = "vulkan/icd.d;glvnd/egl_vendor.d;egl/egl_external_platform.d;\
                                   lib/dri;lib/gbm;vulkan/explicit_layer.d;vulkan/implicit_layer.d";
/// The mount folder of every extension point a generated app may declare ([`extension_points`]).
pub const EXTENSION_DIRS: &[&str] = &[LAUNCHER_DIR, RUNNER_DIR, COMPAT_I386_DIR, GL32_DIR];
/// The vetted art inside `/app`.
pub const ART_IN_APP: &str = "share/ruyaos/play/art";
/// The trust record inside `/app` (`ruya_play_trust::TrustRecord`, 05 §7.1): written by the commit
/// from the verified signatures, never taken from the package (`share/` is reserved).
pub const TRUST_RECORD_IN_APP: &str = "share/ruyaos/play/trust.json";

/// The Flatpak id of a package id.
pub fn app_id(id: &str) -> String {
    format!("play.{id}")
}

/// The ref the commit makes.
pub fn app_ref(id: &str) -> String {
    format!("app/{}/{ARCH}/{BRANCH}", app_id(id))
}

/// A value for a key file line: no control characters (a newline would start a new key), `\`
/// escaped as the key file format wants.
fn keyfile_value(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .replace('\\', "\\\\")
}

/// The English text of a localized map, else its first entry.
fn english(map: &std::collections::BTreeMap<String, String>) -> String {
    map.get("en")
        .or_else(|| map.values().next())
        .cloned()
        .unwrap_or_default()
}

/// One `[Extension <id>]` point of the generated metadata: its mount folder in `/app` and its
/// other keys in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtensionPoint {
    /// The extension id.
    pub id: &'static str,
    /// Its mount folder in `/app` (one of [`EXTENSION_DIRS`]).
    pub directory: &'static str,
    /// The keys after `directory`, in order.
    pub keys: Vec<(&'static str, String)>,
}

/// The extension points of an app of `runner` (ADR-038): the launcher and the system runners
/// (`org.ruyaos.Play.Runner.<Name>` under `/app/runners/<Name>`) for every app, never fetched by
/// Flatpak (the image links them in, `no-autodownload`), and for a Windows runner the freedesktop
/// runtime's 32-bit points as the spike declared them (`scripts/spikes/play/q3-proton.sh`), also
/// `no-autodownload` (offline first: the image preinstalls them, RUY-34). Those
/// are inert unless the package asks for `multiarch`, which is a permission
/// (`ruya_play_trust::permissions`), not something the runner grants.
pub fn extension_points(runner: &str) -> Vec<ExtensionPoint> {
    let s = |v: &str| v.to_string();
    let mut out = vec![
        ExtensionPoint {
            id: LAUNCHER_EXTENSION,
            directory: LAUNCHER_DIR,
            keys: vec![
                ("version", s(PLAY_EXTENSION_BRANCH)),
                ("no-autodownload", s("true")),
            ],
        },
        ExtensionPoint {
            id: RUNNER_EXTENSION,
            directory: RUNNER_DIR,
            keys: vec![
                ("subdirectories", s("true")),
                ("version", s(PLAY_EXTENSION_BRANCH)),
                ("no-autodownload", s("true")),
                ("autodelete", s("false")),
            ],
        },
    ];
    if windows_runner(runner) {
        out.push(ExtensionPoint {
            id: COMPAT_I386_EXTENSION,
            directory: COMPAT_I386_DIR,
            keys: vec![
                ("version", s(RUNTIME_BRANCH)),
                ("no-autodownload", s("true")),
            ],
        });
        out.push(ExtensionPoint {
            id: GL32_EXTENSION,
            directory: GL32_DIR,
            keys: vec![
                ("version", s(GL32_BRANCH)),
                ("versions", format!("{RUNTIME_BRANCH};{GL32_BRANCH}")),
                ("subdirectories", s("true")),
                ("add-ld-path", s("lib")),
                ("merge-dirs", s(GL32_MERGE_DIRS)),
                ("no-autodownload", s("true")),
            ],
        });
    }
    out
}

/// The generated Flatpak metadata, built from the manifest and its assessment (05 §8, RUY-851):
/// what every app gets (IPC, the display socket its runner needs, sound, the GPU) and exactly the
/// lines of `ruya_play_trust::permissions::PERMISSIONS` for each request the assessment holds,
/// then the [`extension_points`] of its runner. Nothing else: no key or value comes from the
/// package (its `env`, `reasons` or field names never reach this file), a request without a row
/// grants nothing, and the extension points are the importer's own.
pub fn metadata(manifest: &Manifest, assessment: &Assessment) -> String {
    let app = app_id(&manifest.id);
    let permissions = metadata_sections(&grants(&manifest.run.runner, assessment));
    let points: Vec<String> = extension_points(&manifest.run.runner)
        .iter()
        .map(|p| {
            let mut section = format!("[Extension {}]\ndirectory={}\n", p.id, p.directory);
            for (key, value) in &p.keys {
                section.push_str(&format!("{key}={value}\n"));
            }
            section
        })
        .collect();
    format!(
        "[Application]\n\
         name={app}\n\
         runtime={RUNTIME}/{ARCH}/{RUNTIME_BRANCH}\n\
         command={LAUNCH_COMMAND}\n\
         \n\
         {permissions}\
         {}",
        points.join("\n")
    )
}

/// The app's own desktop entry (`share/applications/play.<id>.desktop`, category `Game`): what
/// `ruya-library` lists. Flatpak's export rewrites `Exec` to `flatpak run`.
pub fn desktop_entry(manifest: &Manifest) -> String {
    let mut out = String::from("[Desktop Entry]\nType=Application\n");
    out.push_str(&format!(
        "Name={}\n",
        keyfile_value(&english(&manifest.name))
    ));
    if let Some(summary) = &manifest.summary {
        out.push_str(&format!("Comment={}\n", keyfile_value(&english(summary))));
    }
    out.push_str(&format!("Exec={LAUNCH_COMMAND}\n"));
    out.push_str("Categories=Game;\n");
    out.push_str(&format!(
        "X-Ruya-Launch-Mode={}\n",
        keyfile_value(&manifest.run.launch_mode)
    ));
    out
}

/// The mode a staged entry gets before the commit: folders 0755, files 0755 when any execute bit
/// is set (the tree's were checked against `play.files`' `x`) and 0644 otherwise.
pub fn canonical_mode(is_dir: bool, mode: u32) -> u32 {
    if is_dir || mode & 0o111 != 0 {
        0o755
    } else {
        0o644
    }
}

/// Where the commit keeps its state, under `/var/lib/ruya-play`.
#[derive(Debug, Clone)]
pub struct Paths {
    /// The OSTree repo (`bare-user-only`).
    pub repo: PathBuf,
    /// The device key's GPG home (0700).
    pub gnupg: PathBuf,
    /// The device key's fingerprint, once generated.
    pub key_id: PathBuf,
    /// The device key's public part, imported into the remote.
    pub public_key: PathBuf,
}

impl Paths {
    /// The files under `root`.
    pub fn under(root: &Path) -> Paths {
        Paths {
            repo: root.join("repo"),
            gnupg: root.join("gnupg"),
            key_id: root.join("device-key.id"),
            public_key: root.join("device-key.gpg"),
        }
    }
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn v(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| p.to_string()).collect()
}

/// `ostree init` of the staging repo.
pub fn ostree_init(paths: &Paths) -> Vec<String> {
    v(&[
        "ostree",
        "init",
        &format!("--repo={}", s(&paths.repo)),
        "--mode=bare-user-only",
    ])
}

/// Generate the device key (no passphrase: it only says "this console's importer accepted it").
pub fn gpg_generate(paths: &Paths) -> Vec<String> {
    v(&[
        "gpg",
        "--batch",
        "--homedir",
        &s(&paths.gnupg),
        "--pinentry-mode",
        "loopback",
        "--passphrase",
        "",
        "--quick-gen-key",
        "RuyaOS Play device key",
        "ed25519",
        "sign",
        "never",
    ])
}

/// List the secret keys, for the fingerprint.
pub fn gpg_list(paths: &Paths) -> Vec<String> {
    v(&[
        "gpg",
        "--batch",
        "--homedir",
        &s(&paths.gnupg),
        "--list-secret-keys",
        "--with-colons",
    ])
}

/// Export the public key of `fingerprint`.
pub fn gpg_export(paths: &Paths, fingerprint: &str) -> Vec<String> {
    v(&[
        "gpg",
        "--batch",
        "--yes",
        "--homedir",
        &s(&paths.gnupg),
        "--output",
        &s(&paths.public_key),
        "--export",
        fingerprint,
    ])
}

/// The first fingerprint in `gpg --with-colons` output (`fpr:::::::::<40 hex>:`).
pub fn parse_fingerprint(colons: &str) -> Option<String> {
    colons.lines().find_map(|l| {
        let f: Vec<&str> = l.split(':').collect();
        let fpr = *f.get(9)?;
        let ok = f[0] == "fpr" && fpr.len() == 40 && fpr.bytes().all(|b| b.is_ascii_hexdigit());
        ok.then(|| fpr.to_string())
    })
}

/// Add the local remote once (not listed in the Store, not used for dependencies).
pub fn remote_add(paths: &Paths) -> Vec<String> {
    v(&[
        "flatpak",
        "remote-add",
        "--system",
        "--if-not-exists",
        "--no-enumerate",
        "--no-use-for-deps",
        "--title=Installed from packages",
        &format!("--gpg-import={}", s(&paths.public_key)),
        REMOTE,
        &format!("file://{}", s(&paths.repo)),
    ])
}

/// Import the device key into the remote again (a remote from before a new key keeps working).
pub fn remote_modify(paths: &Paths) -> Vec<String> {
    v(&[
        "flatpak",
        "remote-modify",
        "--system",
        &format!("--gpg-import={}", s(&paths.public_key)),
        REMOTE,
    ])
}

/// Finish the build directory: export the desktop entry.
pub fn build_finish(dir: &Path) -> Vec<String> {
    v(&["flatpak", "build-finish", &s(dir)])
}

/// Commit the build directory into the repo, signed with the device key.
pub fn build_export(paths: &Paths, dir: &Path, fingerprint: &str) -> Vec<String> {
    v(&[
        "flatpak",
        "build-export",
        &format!("--gpg-sign={fingerprint}"),
        &format!("--gpg-homedir={}", s(&paths.gnupg)),
        &format!("--arch={ARCH}"),
        &s(&paths.repo),
        &s(dir),
        BRANCH,
    ])
}

/// Install or update the app from the local remote, signature checked.
pub fn install(id: &str) -> Vec<String> {
    v(&[
        "flatpak",
        "install",
        "--system",
        "--or-update",
        "--noninteractive",
        "-y",
        REMOTE,
        &app_ref(id),
    ])
}

/// Runs one command line.
pub trait Runner: Send + Sync {
    /// Run `argv`; its standard output, or why it failed (its standard error).
    fn run(&self, argv: &[String]) -> Result<String, String>;
}

impl<T: Runner + ?Sized> Runner for std::sync::Arc<T> {
    fn run(&self, argv: &[String]) -> Result<String, String> {
        (**self).run(argv)
    }
}

/// The real commands.
#[derive(Debug, Default, Clone, Copy)]
pub struct CommandRunner;

impl Runner for CommandRunner {
    fn run(&self, argv: &[String]) -> Result<String, String> {
        let Some((cmd, args)) = argv.split_first() else {
            return Err("no command".into());
        };
        let out = std::process::Command::new(cmd)
            .args(args)
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("{cmd} could not start ({e})"))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            let err = String::from_utf8_lossy(&out.stderr);
            let err: String = err
                .chars()
                .filter(|c| *c == '\n' || !c.is_control())
                .collect();
            let tail: String = err
                .chars()
                .rev()
                .take(2000)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            Err(format!(
                "{cmd} {} failed ({}): {}",
                args.first().map_or("", String::as_str),
                out.status,
                tail.trim()
            ))
        }
    }
}

/// True when a command's error says the disk is full.
pub fn says_no_space(err: &str) -> bool {
    err.contains("No space left on device") || err.contains("ENOSPC")
}

fn fail(err: String) -> CommitError {
    if says_no_space(&err) {
        CommitError::NoSpace(err)
    } else {
        CommitError::Failed(err)
    }
}

fn io_fail(what: &str, e: &std::io::Error) -> CommitError {
    fail(format!("{what}: {e}"))
}

/// The Flatpak commit over a [`Runner`].
pub struct FlatpakCommit {
    paths: Paths,
    runner: Box<dyn Runner>,
    owner_root: bool,
}

impl FlatpakCommit {
    /// The commit with its state under `root` (`/var/lib/ruya-play`).
    pub fn new(root: &Path, runner: Box<dyn Runner>) -> FlatpakCommit {
        FlatpakCommit {
            paths: Paths::under(root),
            runner,
            owner_root: true,
        }
    }

    /// Leave the owner alone (host tests, which do not run as root); the modes are still set.
    pub fn keeping_owner(mut self) -> FlatpakCommit {
        self.owner_root = false;
        self
    }

    fn run(&self, argv: Vec<String>) -> Result<String, CommitError> {
        self.runner.run(&argv).map_err(fail)
    }

    /// The device key's fingerprint, generating the key on first use.
    pub fn device_key(&self) -> Result<String, CommitError> {
        if let Ok(id) = std::fs::read_to_string(&self.paths.key_id) {
            let id = id.trim().to_string();
            if parse_fingerprint(&format!("fpr:::::::::{id}:")).is_some()
                && self.paths.public_key.is_file()
            {
                return Ok(id);
            }
        }
        create_private_dir(&self.paths.gnupg)
            .map_err(|e| io_fail("the device key's folder", &e))?;
        let listed = self.run(gpg_list(&self.paths)).unwrap_or_default();
        let fpr = match parse_fingerprint(&listed) {
            Some(f) => f,
            None => {
                self.run(gpg_generate(&self.paths))?;
                let listed = self.run(gpg_list(&self.paths))?;
                parse_fingerprint(&listed).ok_or_else(|| {
                    CommitError::Failed("the device key has no fingerprint".into())
                })?
            }
        };
        self.run(gpg_export(&self.paths, &fpr))?;
        write_private(&self.paths.key_id, fpr.as_bytes())
            .map_err(|e| io_fail("the device key's id", &e))?;
        Ok(fpr)
    }

    fn ensure_repo(&self) -> Result<(), CommitError> {
        if !self.paths.repo.join("config").is_file() {
            self.run(ostree_init(&self.paths))?;
        }
        self.run(remote_add(&self.paths))?;
        self.run(remote_modify(&self.paths))?;
        Ok(())
    }
}

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    let mut b = std::fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o700);
    }
    b.create(path)
}

fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut o = std::fs::OpenOptions::new();
    o.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    use std::io::Write;
    o.open(path)?.write_all(bytes)
}

/// Lay out the Flatpak build directory `<job>/app` from the request (see the module docs) and
/// return it.
pub fn lay_out(request: &CommitRequest<'_>) -> Result<PathBuf, CommitError> {
    let manifest = request.manifest;
    // The ceiling refused this before the records; a refused request is never laid out.
    if request.assessment.gate == Gate::Refused {
        return Err(CommitError::Failed(
            "the assessment refuses a request; nothing is granted".into(),
        ));
    }
    let job_dir = request
        .tree
        .parent()
        .ok_or_else(|| CommitError::Failed("the staged tree has no job folder".into()))?;
    // The format refuses these names in the file table before anything is unpacked
    // (`table.reserved_top_level`), so this cannot trigger from a package that passed
    // `inspect`: it stays as an internal invariant of the layout (`commit.failed`).
    for name in RESERVED_TOP_LEVEL {
        if std::fs::symlink_metadata(request.tree.join(name)).is_ok() {
            return Err(CommitError::Failed(format!(
                "the package has a top-level {name:?}, which the console writes itself"
            )));
        }
    }
    let app = job_dir.join("app");
    std::fs::create_dir(&app).map_err(|e| io_fail("the build folder", &e))?;
    let files = app.join("files");
    std::fs::rename(request.tree, &files).map_err(|e| io_fail("moving the tree", &e))?;
    for name in ROOT_FILES {
        let from = request.meta.join(name);
        if from.is_file() {
            let to = files.join(name);
            if std::fs::symlink_metadata(&to).is_ok() {
                return Err(CommitError::Failed(format!("the tree already has {name}")));
            }
            std::fs::copy(&from, &to).map_err(|e| io_fail(name, &e))?;
        }
    }
    let art_parent = files.join("share/ruyaos/play");
    std::fs::create_dir_all(&art_parent).map_err(|e| io_fail("the art folder", &e))?;
    std::fs::rename(request.art, files.join(ART_IN_APP))
        .map_err(|e| io_fail("moving the art", &e))?;
    let record = TrustRecord::of(request.tier, request.signatures, manifest);
    std::fs::write(files.join(TRUST_RECORD_IN_APP), record.to_json())
        .map_err(|e| io_fail("the trust record", &e))?;
    write_generated(&app, manifest, request.assessment)?;
    Ok(app)
}

/// Lay out the Flatpak build folder for a re-commit (ADR-038) next to the copy of an installed
/// app's `/app`, `<staging>/app` with the copy as `app/files`, and return it: the console's own
/// files in the copy (root files, art, trust record) stay as they are; what is generated is
/// written again ([`write_generated`]).
pub fn lay_out_installed(request: &RecommitRequest<'_>) -> Result<PathBuf, CommitError> {
    let job_dir = request
        .files
        .parent()
        .ok_or_else(|| CommitError::Failed("the copy has no staging folder".into()))?;
    let app = job_dir.join("app");
    std::fs::create_dir(&app).map_err(|e| io_fail("the build folder", &e))?;
    std::fs::rename(request.files, app.join("files"))
        .map_err(|e| io_fail("moving the copy", &e))?;
    write_generated(&app, request.manifest, request.assessment)?;
    Ok(app)
}

/// What a commit and a re-commit generate into the build folder `app` from the manifest and its
/// assessment: the mount folder of each of the runner's [`extension_points`] in `files/`, the
/// app's desktop entry and `metadata`.
fn write_generated(
    app: &Path,
    manifest: &Manifest,
    assessment: &Assessment,
) -> Result<(), CommitError> {
    let files = app.join("files");
    let points = extension_points(&manifest.run.runner);
    let dirs: Vec<&str> = points.iter().map(|p| p.directory).collect();
    for p in &points {
        make_mount_folder(&files, p.directory, &dirs).map_err(|why| {
            CommitError::Failed(format!(
                "the app's {} cannot be the mount folder of {}: {why}",
                p.directory, p.id
            ))
        })?;
    }
    let apps = files.join("share/applications");
    std::fs::create_dir_all(&apps).map_err(|e| io_fail("share/applications", &e))?;
    let desktop = apps.join(format!("{}.desktop", app_id(&manifest.id)));
    std::fs::write(&desktop, desktop_entry(manifest))
        .map_err(|e| io_fail("the desktop entry", &e))?;
    std::fs::write(app.join("metadata"), metadata(manifest, assessment))
        .map_err(|e| io_fail("the metadata", &e))?;
    Ok(())
}

/// Make the mount folder `rel` (`/` separated) below `files`, folder by folder, never through a
/// link (a package's own `lib` may be one). A folder that is already there may hold nothing but
/// other mount folders of `mounts`, so a mount never hides a file of the package.
fn make_mount_folder(files: &Path, rel: &str, mounts: &[&str]) -> Result<(), String> {
    let mut at = files.to_path_buf();
    for c in rel.split('/') {
        at.push(c);
        match std::fs::symlink_metadata(&at) {
            Ok(m) if m.is_dir() => {}
            Ok(_) => return Err(format!("{c} is not a folder")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                std::fs::create_dir(&at).map_err(|e| e.to_string())?
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    for e in std::fs::read_dir(&at).map_err(|e| e.to_string())? {
        let e = e.map_err(|e| e.to_string())?;
        let inner = format!("{rel}/{}", e.file_name().to_string_lossy());
        let folder = e.file_type().is_ok_and(|t| t.is_dir());
        if !folder || !mounts.contains(&inner.as_str()) {
            return Err(format!("it holds {inner}"));
        }
    }
    Ok(())
}

/// Root owns everything below `dir`, with [`canonical_mode`] (links keep theirs and are never
/// followed).
#[cfg(unix)]
pub fn canonicalise(dir: &Path, owner_root: bool) -> std::io::Result<()> {
    use std::os::unix::fs::{lchown, PermissionsExt};
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let meta = std::fs::symlink_metadata(&d)?;
        if owner_root {
            lchown(&d, Some(0), Some(0))?;
        }
        if meta.file_type().is_symlink() {
            continue;
        }
        let mode = canonical_mode(meta.is_dir(), meta.permissions().mode());
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(mode))?;
        if meta.is_dir() {
            for e in std::fs::read_dir(&d)? {
                stack.push(e?.path());
            }
        }
    }
    Ok(())
}

impl FlatpakCommit {
    /// The part of a commit after the layout: root owns the build folder `app`, it is finished,
    /// exported signed with the device key `key`, and the app `play.<id>` is installed from it.
    fn publish(
        &self,
        app: &Path,
        id: &str,
        key: &str,
        progress: &mut dyn FnMut(Phase, f32),
    ) -> Result<(), CommitError> {
        #[cfg(unix)]
        canonicalise(app, self.owner_root).map_err(|e| io_fail("making root the owner", &e))?;
        self.run(build_finish(app))?;
        progress(Phase::Committing, 0.3);
        self.run(build_export(&self.paths, app, key))?;
        progress(Phase::Committing, 1.0);
        progress(Phase::Installing, 0.0);
        self.run(install(id))?;
        progress(Phase::Installing, 1.0);
        Ok(())
    }
}

impl Commit for FlatpakCommit {
    fn commit(
        &self,
        request: &CommitRequest<'_>,
        progress: &mut dyn FnMut(Phase, f32),
    ) -> Result<(), CommitError> {
        progress(Phase::Committing, 0.0);
        let key = self.device_key()?;
        self.ensure_repo()?;
        let app = lay_out(request)?;
        self.publish(&app, &request.manifest.id, &key, progress)
    }

    fn recommit(&self, request: &RecommitRequest<'_>) -> Result<(), CommitError> {
        let key = self.device_key()?;
        self.ensure_repo()?;
        let app = lay_out_installed(request)?;
        self.publish(&app, &request.manifest.id, &key, &mut |_, _| {})
    }
}
