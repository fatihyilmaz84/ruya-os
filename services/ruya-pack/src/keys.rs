//! Developer keys: the key file, `RUYA_PACK_KEY`, and the `keygen` command.
//!
//! A key file is two lines, `ruyaos-play-key-v1` and the base64 (RFC 4648, with padding) of the
//! 32-byte Ed25519 seed. `<name>.pub` holds `ruyaos-play-pub-v1` and the base64 of the public key.
//! The key is read from a file or from the environment variable `RUYA_PACK_KEY` (the base64 line
//! alone); there is no option that takes key text, because it would stay in the shell history.
//! No message of this crate ever contains key text, only the key id.

use crate::args::{parse, Spec};
use crate::fixes::codes;
use crate::report::{Item, Reply, Stop};
use crate::Context;
use base64ct::{Base64, Encoding};
use ruya_play_trust::{generate_key, SecretKey};
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};

/// First line of a key file.
pub const KEY_HEADER: &str = "ruyaos-play-key-v1";
/// First line of a public key file.
pub const PUB_HEADER: &str = "ruyaos-play-pub-v1";

fn invalid(what: &str) -> Item {
    Item::new(codes::KEY_INVALID, "", what)
}

/// The text of a key file for `key`.
pub fn key_file_text(key: &SecretKey) -> String {
    format!("{KEY_HEADER}\n{}\n", Base64::encode_string(&key.seed()))
}

fn seed_from_base64(text: &str) -> Option<SecretKey> {
    let bytes = Base64::decode_vec(text.trim()).ok()?;
    let seed: [u8; 32] = bytes.try_into().ok()?;
    Some(SecretKey::from_seed(&seed))
}

/// Read the key out of the text of a key file.
pub fn parse_key_file(text: &str) -> Result<SecretKey, Item> {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some(KEY_HEADER) {
        return Err(invalid(
            "The file is not a ruya-pack key file (its first line is not ruyaos-play-key-v1).",
        ));
    }
    let key = lines.next().and_then(seed_from_base64);
    if lines.any(|l| !l.trim().is_empty()) {
        return Err(invalid("The key file has more than its two lines."));
    }
    key.ok_or_else(|| invalid("The key file's second line is not the base64 of a 32-byte key."))
}

/// Load a key from `file`, or from `RUYA_PACK_KEY` when no file is given.
pub fn load(file: Option<&str>, ctx: &Context) -> Result<SecretKey, Stop> {
    load_named(file, ctx, "--key")
}

pub(crate) fn load_named(file: Option<&str>, ctx: &Context, flag: &str) -> Result<SecretKey, Stop> {
    let bad = |item: Item| Stop::Usage(format!("{} ({})", item.message, item.code));
    match file {
        Some(path) => {
            let text = std::fs::read_to_string(path).map_err(|e| {
                // A key typed where a file name belongs must not be echoed back.
                if seed_from_base64(path).is_some() {
                    Stop::Usage(format!(
                        "{flag} takes the name of a key file, not the key itself; put the key in a file or in RUYA_PACK_KEY"
                    ))
                } else {
                    Stop::io("cannot read the key file", Path::new(path), &e)
                }
            })?;
            parse_key_file(&text).map_err(bad)
        }
        None => match &ctx.key_env {
            Some(v) => seed_from_base64(v)
                .ok_or_else(|| bad(invalid("RUYA_PACK_KEY is not the base64 of a 32-byte key."))),
            None => Err(Stop::Usage(format!(
                "no key: pass {flag} <file> or set RUYA_PACK_KEY ({})",
                codes::KEY_MISSING
            ))),
        },
    }
}

fn create_private(path: &Path, text: &str, force: bool) -> std::io::Result<()> {
    let mut o = std::fs::OpenOptions::new();
    o.write(true);
    if force {
        o.create(true).truncate(true);
    } else {
        o.create_new(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    let mut f = o.open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // An existing file keeps its old mode when truncated: set it.
        f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    f.write_all(text.as_bytes())?;
    f.sync_all()
}

fn with_ext(name: &str, ext: &str) -> PathBuf {
    PathBuf::from(format!("{name}.{ext}"))
}

/// `keygen <name> [--force]`: writes `<name>.key` (mode 0600 on Unix) and `<name>.pub`, and
/// prints only the key id and the public key.
pub fn keygen(args: &[String], _ctx: &Context) -> Result<Reply, Stop> {
    let p = parse(
        args,
        &Spec {
            values: &[],
            switches: &["force"],
            positionals: (1, 1),
        },
    )?;
    let name = &p.positional[0];
    let force = p.has("force");
    let (key_path, pub_path) = (with_ext(name, "key"), with_ext(name, "pub"));
    let mut reply = Reply::default();
    for path in [&key_path, &pub_path] {
        if !force && path.exists() {
            reply.problems.push(Item::new(
                codes::KEY_EXISTS,
                path.display().to_string(),
                "The file exists already; keygen never replaces a key silently.",
            ));
        }
    }
    if !reply.problems.is_empty() {
        return Ok(reply);
    }
    let key = generate_key().map_err(|e| Stop::Io(format!("no random numbers available ({e})")))?;
    let public = key.public();
    create_private(&key_path, &key_file_text(&key), force)
        .map_err(|e| Stop::io("cannot write", &key_path, &e))?;
    let pub_text = format!("{PUB_HEADER}\n{}\n", public.to_base64());
    std::fs::write(&pub_path, pub_text).map_err(|e| Stop::io("cannot write", &pub_path, &e))?;
    reply.text = format!(
        "key id:     {}\npublic key: {}\nprivate key written to {} (keep it secret, back it up)\n",
        public.key_id(),
        public.to_base64(),
        key_path.display()
    );
    reply.fields.insert("key_id".into(), json!(public.key_id()));
    reply
        .fields
        .insert("public_key".into(), json!(public.to_base64()));
    reply
        .fields
        .insert("key_file".into(), json!(key_path.display().to_string()));
    reply
        .fields
        .insert("public_file".into(), json!(pub_path.display().to_string()));
    Ok(reply)
}
