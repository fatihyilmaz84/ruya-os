//! `init <dir>`: a skeleton package. `play.json` is plain JSON (no comments are allowed in it), so
//! the explanations live in `README.txt`. The placeholder icon is 64x64 on purpose: `validate`
//! says `art.too_small` until it is replaced by a 512x512 image.

use crate::args::{parse, Spec};
use crate::fixes::codes;
use crate::png;
use crate::report::{Item, Reply, Stop};
use crate::Context;
use serde_json::json;
use std::path::Path;

const SPEC: Spec = Spec {
    values: &["id", "name"],
    switches: &["force"],
    positionals: (1, 1),
};

const README: &str = "\
This folder is a RuyaOS .play package in the making.

  play.json    the manifest. Edit it: id, name, version, build, art, run, permissions.
               (Spec: docs/specs/05-play-packages.md section 4.1. JSON allows no comments.)
  art/         icon and other art. art/icon.png is a 64x64 PLACEHOLDER: replace it with a
               512x512 PNG (square), or `validate` keeps saying art.too_small.
  payload/     your game or app. run.sh is a placeholder program; point run.command at your own.
  licences/    licence texts (and source offers) for any third-party code you bundle.
  components/  bundled runners such as components/wine/, if you ship your own.

Next steps, from the folder above this one:

  ruya-pack validate <this folder>      checks every rule that can run off the device
  ruya-pack build <this folder>        writes play.files and a deterministic .play.zip
  ruya-pack keygen mykey               makes a signing key (keep mykey.key secret)
  ruya-pack sign <the zip> --key mykey.key
  ruya-pack inspect <the zip>          shows what the console will show

Every command takes --json for a machine-readable result. Delete this README.txt before you
publish, or keep it: it is listed in play.files like any other file.
";

const RUN_SH: &str = "#!/bin/sh\n# Placeholder: replace with your game and change run.command in play.json.\necho \"Hello from my RuyaOS game\"\n";

fn manifest(id: &str, name: &str) -> String {
    let q = |s: &str| serde_json::to_string(s).unwrap_or_default();
    format!(
        "{{\n  \"format\": 1,\n  \"id\": {id},\n  \"name\": {{ \"en\": {name} }},\n  \"version\": \"0.1.0\",\n  \"build\": 1,\n  \"summary\": {{ \"en\": \"One sentence about the game.\" }},\n  \"art\": {{ \"icon\": \"art/icon.png\" }},\n  \"run\": {{\n    \"runner\": \"native\",\n    \"command\": [\"${{payload}}/run.sh\"]\n  }},\n  \"permissions\": {{ \"input\": \"controllers+keyboard-mouse\", \"network\": false }}\n}}\n",
        id = q(id),
        name = q(name)
    )
}

/// `init`.
pub fn run(args: &[String], _ctx: &Context) -> Result<Reply, Stop> {
    let p = parse(args, &SPEC)?;
    let dir = Path::new(&p.positional[0]);
    let id = p.one("id").unwrap_or("com.example.mygame");
    let name = p.one("name").unwrap_or("My Game");
    let mut reply = Reply::default();
    let occupied = std::fs::read_dir(dir).is_ok_and(|mut d| d.next().is_some());
    if occupied && !p.has("force") {
        reply.problems.push(Item::new(
            codes::INIT_NOT_EMPTY,
            dir.display().to_string(),
            "The folder is not empty; init does not touch an existing package.",
        ));
        return Ok(reply);
    }
    let write = |rel: &str, bytes: &[u8]| -> Result<bool, Stop> {
        let path = rel.split('/').fold(dir.to_path_buf(), |a, c| a.join(c));
        if path.exists() {
            return Ok(false);
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Stop::io("cannot create", parent, &e))?;
        }
        std::fs::write(&path, bytes).map_err(|e| Stop::io("cannot write", &path, &e))?;
        Ok(true)
    };
    let mut made = Vec::new();
    let files: [(&str, Vec<u8>); 4] = [
        ("play.json", manifest(id, name).into_bytes()),
        ("README.txt", README.as_bytes().to_vec()),
        ("art/icon.png", png::solid(64, 64, [0x2b, 0x6c, 0xb0, 0xff])),
        ("payload/run.sh", RUN_SH.as_bytes().to_vec()),
    ];
    for (rel, bytes) in &files {
        if write(rel, bytes)? {
            made.push(rel.to_string());
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let run_sh = dir.join("payload").join("run.sh");
        // The executable bit is recorded from the source folder by `build`.
        if made.iter().any(|m| m == "payload/run.sh") {
            std::fs::set_permissions(&run_sh, std::fs::Permissions::from_mode(0o755))
                .map_err(|e| Stop::io("cannot write", &run_sh, &e))?;
        }
    }
    let licences = dir.join("licences");
    std::fs::create_dir_all(&licences).map_err(|e| Stop::io("cannot create", &licences, &e))?;
    reply.text = format!(
        "wrote a skeleton package to {}:\n  {}\nnext: replace art/icon.png (it is a 64x64 placeholder), edit play.json, then ruya-pack validate {}\n",
        dir.display(),
        made.join("\n  "),
        dir.display()
    );
    reply
        .fields
        .insert("dir".into(), json!(dir.display().to_string()));
    reply.fields.insert("files".into(), json!(made));
    Ok(reply)
}
