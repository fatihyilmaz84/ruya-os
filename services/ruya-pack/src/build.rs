//! `build <dir> [-o out.play.zip]`: writes `play.files` into the folder (sorted, hashed, with links
//! and executable bits recorded from the source), builds the deterministic zip, and runs
//! `validate` on the result. Nothing is left behind when the result does not pass.

use crate::args::{parse, Spec};
use crate::fixes::codes;
use crate::pkg;
use crate::report::{items, Item, Reply, Stop};
use crate::validate;
use crate::zipw::{self, FileSrc};
use crate::Context;
use flate2::Crc;
use ruya_play_format::limits::ROOT_FILES;
use ruya_play_format::{codes as fcodes, EntryKind, FolderSource, Source};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

const SPEC: Spec = Spec {
    values: &[
        "output",
        "exec",
        "system-wine",
        "system-proton-ge",
        "system-runner",
    ],
    switches: &["deflate", "links-as-data"],
    positionals: (1, 1),
};

enum Planned {
    File {
        path: String,
        size: u64,
        sha256: String,
        crc: u32,
        executable: bool,
    },
    Link {
        path: String,
        to: String,
    },
    Dir {
        path: String,
    },
}

impl Planned {
    fn path(&self) -> &str {
        match self {
            Planned::File { path, .. } | Planned::Link { path, .. } | Planned::Dir { path } => path,
        }
    }

    fn line(&self) -> String {
        let q = |s: &str| serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into());
        match self {
            Planned::File {
                path,
                size,
                sha256,
                executable,
                ..
            } => format!(
                "{{\"p\":{},\"t\":\"f\",\"s\":{size},\"h\":\"{sha256}\"{}}}\n",
                q(path),
                if *executable { ",\"x\":1" } else { "" }
            ),
            Planned::Link { path, to } => {
                format!("{{\"p\":{},\"t\":\"l\",\"to\":{}}}\n", q(path), q(to))
            }
            Planned::Dir { path } => format!("{{\"p\":{},\"t\":\"d\"}}\n", q(path)),
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

/// Size, SHA-256, CRC-32 and the first bytes of a file, in one read.
fn digest(path: &Path) -> std::io::Result<(u64, String, u32, Vec<u8>)> {
    let mut f = std::fs::File::open(path)?;
    let (mut sha, mut crc, mut total) = (Sha256::new(), Crc::new(), 0u64);
    let (mut buf, mut head) = (vec![0u8; 256 * 1024], Vec::new());
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        if head.len() < 4 {
            head.extend_from_slice(&buf[..n.min(4 - head.len())]);
        }
        sha.update(&buf[..n]);
        crc.update(&buf[..n]);
        total += n as u64;
    }
    Ok((total, hex(&sha.finalize()), crc.sum(), head))
}

#[cfg(unix)]
fn mode_executable(path: &Path, _head: &[u8]) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
}

/// Windows has no executable bit: a file that starts like a program or a script gets one.
#[cfg(not(unix))]
fn mode_executable(_path: &Path, head: &[u8]) -> bool {
    head.starts_with(b"\x7fELF") || head.starts_with(b"#!")
}

/// A relative link target that stays inside the package: lexically, never above the root.
fn link_target(link: &str, full: &Path) -> Result<String, String> {
    let target = std::fs::read_link(full).map_err(|e| format!("cannot read the link ({e})"))?;
    let text = target.to_string_lossy().replace('\\', "/");
    if target.has_root()
        || text.starts_with('/')
        || target
            .components()
            .any(|c| matches!(c, Component::Prefix(_) | Component::RootDir))
    {
        return Err(format!("the link points to the absolute path {text}"));
    }
    let mut depth = link.matches('/').count() as i64; // folders above the link inside the package
    for part in text.split('/') {
        match part {
            "" | "." => {}
            ".." => depth -= 1,
            _ => depth += 1,
        }
        if depth < 0 {
            return Err(format!("the link {text} leaves the package"));
        }
    }
    Ok(text)
}

/// `build`.
pub fn run(args: &[String], ctx: &Context) -> Result<Reply, Stop> {
    let _ = ctx;
    let p = parse(args, &SPEC)?;
    let dir = PathBuf::from(&p.positional[0]);
    if !dir.is_dir() {
        return Err(Stop::Usage(format!(
            "{} is not a folder; build takes the package folder",
            dir.display()
        )));
    }
    let runners = validate::runners_from(&p)?;
    let mut reply = Reply::default();
    let listed = match FolderSource::new(&dir).entries() {
        Ok(e) => e,
        Err(problems) => {
            reply.problems = items(&problems);
            return Ok(reply);
        }
    };
    let execs: BTreeSet<&str> = p.all("exec").iter().map(String::as_str).collect();
    let links_as_data = p.has("links-as-data");

    let mut planned: Vec<Planned> = Vec::new();
    let mut dirs: Vec<String> = Vec::new();
    for e in &listed {
        if e.path == "play.files" {
            continue; // rewritten below
        }
        if e.path == "play.sig" || e.path == "store.sig" {
            reply.warnings.push(Item::new(
                codes::BUILD_SIGNATURE_DROPPED,
                e.path.clone(),
                format!(
                    "{} is not part of the build: play.files is rewritten, so an old signature would no longer match.",
                    e.path
                ),
            ));
            continue;
        }
        let full = e.path.split('/').fold(dir.clone(), |a, c| a.join(c));
        match e.kind {
            EntryKind::Dir => dirs.push(e.path.clone()),
            EntryKind::File if ROOT_FILES.contains(&e.path.as_str()) => {}
            EntryKind::File => {
                let (size, sha256, crc, head) =
                    digest(&full).map_err(|er| Stop::io("cannot read", &full, &er))?;
                let executable = mode_executable(&full, &head) || execs.contains(e.path.as_str());
                planned.push(Planned::File {
                    path: e.path.clone(),
                    size,
                    sha256,
                    crc,
                    executable,
                });
            }
            EntryKind::Symlink if links_as_data => match link_target(&e.path, &full) {
                Ok(to) => planned.push(Planned::Link {
                    path: e.path.clone(),
                    to,
                }),
                Err(why) => reply.problems.push(Item::new(
                    codes::BUILD_SYMLINK_UNSUPPORTED,
                    e.path.clone(),
                    why,
                )),
            },
            EntryKind::Symlink => reply.problems.push(Item::new(
                codes::BUILD_SYMLINK,
                e.path.clone(),
                "This is a real symbolic link; a package holds only regular files and folders.",
            )),
            EntryKind::HardLink => reply.problems.push(Item::new(
                fcodes::ENTRY_HARDLINK,
                e.path.clone(),
                "This is a hard link; copy the file instead.",
            )),
            EntryKind::Device => reply.problems.push(Item::new(
                fcodes::ENTRY_DEVICE,
                e.path.clone(),
                "This is a device file.",
            )),
            EntryKind::Other => reply.problems.push(Item::new(
                fcodes::ENTRY_SPECIAL,
                e.path.clone(),
                "This is a special file.",
            )),
        }
    }
    if !reply.problems.is_empty() {
        return Ok(reply);
    }
    // A folder is listed only when nothing is below it.
    let empty: Vec<String> = {
        let occupied: BTreeSet<&str> = planned
            .iter()
            .map(Planned::path)
            .chain(dirs.iter().map(String::as_str))
            .filter_map(|p| p.rsplit_once('/').map(|(parent, _)| parent))
            .collect();
        dirs.iter()
            .filter(|d| !occupied.contains(d.as_str()))
            .cloned()
            .collect()
    };
    planned.extend(empty.into_iter().map(|path| Planned::Dir { path }));
    planned.sort_by(|a, b| a.path().as_bytes().cmp(b.path().as_bytes()));
    let table: String = planned.iter().map(Planned::line).collect();

    // Where the zip goes.
    let out = match p.one("output") {
        Some(o) => PathBuf::from(o),
        None => default_output(&dir)?,
    };
    if inside(&dir, &out) {
        reply.problems.push(Item::new(
            codes::BUILD_OUTPUT_INSIDE,
            out.display().to_string(),
            "The output file would be inside the package folder, and so part of the next build.",
        ));
        return Ok(reply);
    }

    write_if_changed(&dir.join("play.files"), table.as_bytes())?;

    // The zip: files and empty folders, links only as table lines.
    let mut entries: Vec<zipw::Entry<'_>> = Vec::new();
    for pl in &planned {
        match pl {
            Planned::File {
                path,
                size,
                crc,
                executable,
                ..
            } => entries.push(zipw::Entry {
                name: path.clone(),
                item: zipw::Item::File {
                    src: FileSrc::Path(path.split('/').fold(dir.clone(), |a, c| a.join(c))),
                    size: *size,
                    crc: Some(*crc),
                    executable: *executable,
                },
            }),
            Planned::Dir { path } => entries.push(zipw::Entry {
                name: path.clone(),
                item: zipw::Item::Dir,
            }),
            Planned::Link { .. } => {}
        }
    }
    let manifest_path = dir.join("play.json");
    if let Ok(m) = std::fs::metadata(&manifest_path) {
        if m.is_file() {
            entries.push(zipw::Entry {
                name: "play.json".to_string(),
                item: zipw::Item::File {
                    src: FileSrc::Path(manifest_path),
                    size: m.len(),
                    crc: None,
                    executable: false,
                },
            });
        } // else validate names the missing or wrong play.json
    }
    entries.push(zipw::Entry {
        name: "play.files".into(),
        item: zipw::Item::File {
            src: FileSrc::Bytes(table.clone().into_bytes()),
            size: table.len() as u64,
            crc: None,
            executable: false,
        },
    });
    let tmp = PathBuf::from(format!("{}.tmp", out.display()));
    let written = (|| -> std::io::Result<u64> {
        let f = std::fs::File::create(&tmp)?;
        zipw::write_zip(
            f,
            entries,
            zipw::Options {
                deflate: p.has("deflate"),
                ..zipw::Options::default()
            },
        )
    })()
    .map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Stop::io("cannot write", &tmp, &e)
    })?;

    // Validate the result: the console reads exactly this file.
    let opened = match pkg::open(&tmp.to_string_lossy()) {
        Ok(o) => o,
        Err(pkg::OpenError::Stop(s)) => {
            let _ = std::fs::remove_file(&tmp);
            return Err(s);
        }
        Err(pkg::OpenError::Problems(problems)) => {
            let _ = std::fs::remove_file(&tmp);
            reply.problems = problems;
            return Ok(reply);
        }
    };
    let checked = validate::check(&*opened.source, &runners, opened.file_bytes);
    let mut v = validate::report(&opened, checked);
    drop(opened);
    reply.problems.append(&mut v.problems);
    reply.warnings.append(&mut v.warnings);
    reply.fields = v.fields;
    if !reply.problems.is_empty() {
        let _ = std::fs::remove_file(&tmp);
        return Ok(reply);
    }
    let sha = digest(&tmp)
        .map(|d| d.1)
        .map_err(|e| Stop::io("cannot read", &tmp, &e))?;
    std::fs::rename(&tmp, &out).map_err(|e| Stop::io("cannot write", &out, &e))?;
    reply
        .fields
        .insert("output".into(), json!(out.display().to_string()));
    reply.fields.insert("bytes".into(), json!(written));
    reply.fields.insert("sha256".into(), json!(sha));
    reply.fields.insert("entries".into(), json!(planned.len()));
    reply.text = format!(
        "built {} ({written} bytes, sha256 {sha})\n{}",
        out.display(),
        v.text
    );
    Ok(reply)
}

fn default_output(dir: &Path) -> Result<PathBuf, Stop> {
    let abs = std::fs::canonicalize(dir).map_err(|e| Stop::io("cannot open", dir, &e))?;
    let name = abs
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "package".into());
    let name = name.strip_suffix(".play").unwrap_or(&name).to_string();
    Ok(abs
        .parent()
        .unwrap_or(Path::new("."))
        .join(format!("{name}.play.zip")))
}

fn inside(dir: &Path, out: &Path) -> bool {
    let (Ok(d), parent) = (
        std::fs::canonicalize(dir),
        out.parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new(".")),
    ) else {
        return false;
    };
    std::fs::canonicalize(parent)
        .is_ok_and(|p| p.join(out.file_name().unwrap_or_default()).starts_with(&d))
}

fn write_if_changed(path: &Path, bytes: &[u8]) -> Result<(), Stop> {
    if std::fs::read(path).is_ok_and(|old| old == bytes) {
        return Ok(());
    }
    let tmp = path.with_extension("files.tmp");
    std::fs::write(&tmp, bytes).map_err(|e| Stop::io("cannot write", &tmp, &e))?;
    std::fs::rename(&tmp, path).map_err(|e| Stop::io("cannot write", path, &e))
}
