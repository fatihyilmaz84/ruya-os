//! `sign <pkg> [--key <file>] [--rotate-from <old key file>]`: writes `play.sig` (05 section 9.2)
//! with the crate the console verifies with. The key comes from a file or from `RUYA_PACK_KEY`.

use crate::args::{parse, Spec};
use crate::keys;
use crate::pkg::{self, OpenError};
use crate::report::{items, Item, Reply, Stop};
use crate::zipw::{self, FileSrc};
use crate::Context;
use ruya_play_format::limits::{MAX_MANIFEST_BYTES, MAX_TABLE_BYTES};
use ruya_play_format::{read_within, validate, EntryKind, FileEntry, ValidateOptions};
use ruya_play_trust::time::{format_utc, parse_utc};
use ruya_play_trust::{
    bind_to_manifest, sign_package, sign_rotation, verify_signatures, PackageBytes, SecretKey,
    StoreKeys, TrustError,
};
use serde_json::{json, Value};
use std::path::Path;

/// What goes into one `play.sig`.
pub struct SignInput<'a> {
    /// The developer's key.
    pub key: &'a SecretKey,
    /// The package id.
    pub id: &'a str,
    /// The package build.
    pub build: u64,
    /// The bytes of `play.json`.
    pub play_json: &'a [u8],
    /// The bytes of `play.files`.
    pub play_files: &'a [u8],
    /// Seconds since 1970 (UTC) written into the statement.
    pub signed_at: i64,
    /// The key the id was handed over from, when `key` is a new key.
    pub rotate_from: Option<&'a SecretKey>,
    /// Rotation envelopes the package already carries (an earlier rotation of the same id).
    pub carried: &'a [Vec<u8>],
    /// The number of the new rotation; default is one above the carried ones.
    pub rotation_seq: Option<u64>,
}

/// The `play.sig` bytes: exactly what `ruya-pack sign` writes.
pub fn sign_bytes(i: &SignInput<'_>) -> Result<Vec<u8>, TrustError> {
    let mut rotations: Vec<Vec<u8>> = i.carried.to_vec();
    if let Some(old) = i.rotate_from {
        let seq = i.rotation_seq.unwrap_or(rotations.len() as u64 + 1);
        rotations.push(sign_rotation(old, i.id, &i.key.public(), seq, i.signed_at));
    }
    let refs: Vec<&[u8]> = rotations.iter().map(Vec::as_slice).collect();
    sign_package(
        i.key,
        i.id,
        i.build,
        i.play_json,
        i.play_files,
        i.signed_at,
        &refs,
    )
}

/// The rotation envelopes inside an existing `play.sig`, as bytes (none when it has none or is
/// not readable; the old signature is replaced anyway).
pub fn carried_rotations(play_sig: &[u8]) -> Vec<Vec<u8>> {
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(play_sig) else {
        return Vec::new();
    };
    match obj.get("rotations") {
        Some(Value::Array(list)) => list
            .iter()
            .filter_map(|r| serde_json::to_vec(r).ok())
            .collect(),
        _ => Vec::new(),
    }
}

const SPEC: Spec = Spec {
    values: &["key", "rotate-from", "signed-at", "rotation-seq"],
    switches: &["deflate"],
    positionals: (1, 1),
};

/// `sign`.
pub fn run(args: &[String], ctx: &Context) -> Result<Reply, Stop> {
    let p = parse(args, &SPEC)?;
    let key = keys::load(p.one("key"), ctx)?;
    let old = match p.one("rotate-from") {
        Some(f) => Some(keys::load_named(Some(f), ctx, "--rotate-from")?),
        None => None,
    };
    if old.as_ref().is_some_and(|o| o.public() == key.public()) {
        return Err(Stop::UsageCode(
            crate::fixes::codes::KEY_SAME,
            "--rotate-from is the same key as the signing key".into(),
        ));
    }
    let signed_at = match p.one("signed-at") {
        Some(t) => parse_utc(t).ok_or_else(|| {
            Stop::Usage(format!(
                "--signed-at takes YYYY-MM-DDTHH:MM:SSZ, not {}",
                crate::report::redact(t)
            ))
        })?,
        None => ctx.now,
    };
    let seq = match p.one("rotation-seq") {
        Some(s) => Some(
            s.parse::<u64>()
                .ok()
                .filter(|n| *n >= 1)
                .ok_or_else(|| Stop::Usage("--rotation-seq takes a number from 1".into()))?,
        ),
        None => None,
    };
    let opened = match pkg::open(&p.positional[0]) {
        Ok(o) => o,
        Err(OpenError::Stop(s)) => return Err(s),
        Err(OpenError::Problems(problems)) => {
            return Ok(Reply {
                problems,
                ..Reply::default()
            })
        }
    };
    let package = match validate(&*opened.source, &ValidateOptions::default()) {
        Ok(pk) => pk,
        Err(problems) => {
            return Ok(Reply {
                problems: items(&problems),
                ..Reply::default()
            })
        }
    };
    let unreadable = |name: &str| Stop::Io(format!("cannot read {name} of the package"));
    // The format's one bounded reader; `None` when a file is absent, unreadable or longer.
    let read = |name: &str, limit: u64| read_within(&*opened.source, name, limit).ok().flatten();
    let play_json = read("play.json", MAX_MANIFEST_BYTES).ok_or_else(|| unreadable("play.json"))?;
    let play_files = read("play.files", MAX_TABLE_BYTES).ok_or_else(|| unreadable("play.files"))?;
    let carried = read("play.sig", 64 * 1024)
        .map(|s| carried_rotations(&s))
        .unwrap_or_default();
    let sig = sign_bytes(&SignInput {
        key: &key,
        id: &package.manifest.id,
        build: package.manifest.build,
        play_json: &play_json,
        play_files: &play_files,
        signed_at,
        rotate_from: old.as_ref(),
        carried: &carried,
        rotation_seq: seq,
    })
    .map_err(|e| Stop::Io(format!("cannot sign: {e}")))?;

    // The console's verifier must accept what was just written.
    let sigs = verify_signatures(
        &PackageBytes {
            play_json: &play_json,
            play_files: &play_files,
            play_sig: Some(&sig),
            store_sig: None,
        },
        &StoreKeys::none(),
    )
    .and_then(|s| bind_to_manifest(&s, &package.manifest).map(|()| s));
    let mut reply = Reply::default();
    let sigs = match sigs {
        Ok(s) => s,
        Err(e) => {
            reply
                .problems
                .push(Item::new(e.code(), e.path(), e.message()));
            return Ok(reply);
        }
    };
    let rotations = sigs.developer.as_ref().map_or(0, |d| d.rotations.len());

    if opened.is_dir {
        let target = opened.path.join("play.sig");
        let tmp = opened.path.join("play.sig.tmp");
        std::fs::write(&tmp, &sig).map_err(|e| Stop::io("cannot write", &tmp, &e))?;
        std::fs::rename(&tmp, &target).map_err(|e| Stop::io("cannot write", &target, &e))?;
        if opened
            .source
            .entries()
            .is_ok_and(|e| e.iter().any(|x| x.path == "store.sig"))
        {
            reply.warnings.push(Item::new(
                "build.signature_dropped",
                "store.sig",
                "store.sig countersigned the old play.sig and no longer matches; delete it.",
            ));
        }
    } else {
        rewrite_zip(
            &opened.path,
            opened.source,
            &package.files,
            &sig,
            p.has("deflate"),
            &mut reply,
        )?;
    }
    let key_id = key.public().key_id();
    reply.text = format!(
        "signed {} build {} with key {key_id}{}\n",
        package.manifest.id,
        package.manifest.build,
        if rotations > 0 {
            format!(" ({rotations} rotation(s) carried)")
        } else {
            String::new()
        }
    );
    reply.fields.insert("id".into(), json!(package.manifest.id));
    reply
        .fields
        .insert("build".into(), json!(package.manifest.build));
    reply.fields.insert("key_id".into(), json!(key_id));
    reply.fields.insert("tier".into(), json!("developer"));
    reply
        .fields
        .insert("signed_at".into(), json!(format_utc(signed_at)));
    reply.fields.insert("rotations".into(), json!(rotations));
    Ok(reply)
}

/// Write the zip again with `play.sig` added (every entry copied, stored unless `deflate`).
fn rewrite_zip(
    path: &Path,
    source: Box<dyn ruya_play_format::Source>,
    files: &[FileEntry],
    sig: &[u8],
    deflate: bool,
    reply: &mut Reply,
) -> Result<(), Stop> {
    let listed = source
        .entries()
        .map_err(|_| Stop::Io("cannot list the zip again".into()))?;
    let executable_files: std::collections::HashSet<&str> = files
        .iter()
        .filter_map(|f| match f {
            FileEntry::File {
                path,
                executable: true,
                ..
            } => Some(path.as_str()),
            _ => None,
        })
        .collect();
    let executable = |name: &str| executable_files.contains(name);
    let mut entries: Vec<zipw::Entry<'_>> = Vec::new();
    for e in &listed {
        if e.path == "play.sig" {
            continue;
        }
        if e.path == "store.sig" {
            reply.warnings.push(Item::new(
                "build.signature_dropped",
                "store.sig",
                "store.sig countersigned the old play.sig and is not copied.",
            ));
            continue;
        }
        let item = match e.kind {
            EntryKind::Dir => zipw::Item::Dir,
            _ => zipw::Item::File {
                src: FileSrc::Source(&*source, e.path.clone()),
                size: e.size,
                crc: None,
                executable: executable(&e.path),
            },
        };
        entries.push(zipw::Entry {
            name: e.path.trim_end_matches('/').to_string(),
            item,
        });
    }
    entries.push(zipw::Entry {
        name: "play.sig".into(),
        item: zipw::Item::File {
            src: FileSrc::Bytes(sig.to_vec()),
            size: sig.len() as u64,
            crc: None,
            executable: false,
        },
    });
    let tmp = path.with_extension("zip.tmp");
    let written = (|| -> std::io::Result<u64> {
        let f = std::fs::File::create(&tmp)?;
        zipw::write_zip(
            f,
            entries,
            zipw::Options {
                deflate,
                ..zipw::Options::default()
            },
        )
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(Stop::io("cannot write", &tmp, &e));
    }
    drop(source); // the zip is still open for reading; Windows cannot replace an open file
    std::fs::rename(&tmp, path).map_err(|e| Stop::io("cannot write", path, &e))
}
