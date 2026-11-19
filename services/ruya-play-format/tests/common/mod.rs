//! Fixture packages, generated here (no binary blobs in git): a builder for valid packages that a
//! test then breaks in one way, and a small zip writer that can write the zips real tools refuse to.
#![allow(dead_code)]

use flate2::write::DeflateEncoder;
use flate2::Compression;
use ruya_play_format::{
    validate, EntryKind, MemorySource, Package, Problem, Source, ValidateOptions, ZipSource,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::io::{Cursor, Write};
use std::path::Path;

pub fn sha_hex(data: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(64);
    for b in Sha256::digest(data) {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 15) as usize] as char);
    }
    out
}

/// A package under construction.
#[derive(Clone)]
pub struct Fx {
    pub manifest: Value,
    /// Regular files (not the root metadata files).
    pub files: Vec<(String, Vec<u8>)>,
    pub exec: BTreeSet<String>,
    /// Empty directories listed in the table.
    pub dirs: Vec<String>,
    /// Links listed in the table: (path, target).
    pub links: Vec<(String, String)>,
    pub table_override: Option<Vec<u8>>,
    pub manifest_override: Option<Vec<u8>>,
}

impl Fx {
    pub fn minimal() -> Fx {
        Fx {
            manifest: json!({
                "format": 1,
                "id": "com.example.mini",
                "name": {"en": "Mini"},
                "version": "1.0",
                "build": 1,
                "art": {"icon": "art/icon.png"},
                "run": {"runner": "native", "command": ["${payload}/game"]}
            }),
            files: vec![
                ("art/icon.png".into(), b"not really a png".to_vec()),
                ("payload/game".into(), b"#!/bin/sh\necho hi\n".to_vec()),
            ],
            exec: ["payload/game".to_string()].into_iter().collect(),
            dirs: vec![],
            links: vec![],
            table_override: None,
            manifest_override: None,
        }
    }

    pub fn wine_full() -> Fx {
        let mut fx = Fx::minimal();
        fx.manifest = json!({
            "format": 1,
            "id": "com.example.starhopper",
            "name": {"en": "Star Hopper", "tr": "Yildiz Atlayici"},
            "version": "1.4.2",
            "build": 142,
            "summary": {"en": "A two-player space platformer."},
            "description": {"en": "Hop between planets.\n\nSecond paragraph."},
            "developer": {"name": "Example Games", "url": "https://example.com"},
            "publisher": {"name": "Example Publishing"},
            "release_date": "2021-03-04",
            "genres": ["platformer", "adventure"],
            "tags": ["co-op", "space", "pixel-art"],
            "languages": ["en", "tr", "pt-BR"],
            "players": {"min": 1, "max": 2, "modes": ["single", "local"]},
            "controller": "full",
            "age_rating": {"scheme": "oars-1.1", "content": {"violence-cartoon": "mild"}},
            "licence": {"package": "LicenseRef-proprietary", "terms_url": "https://example.com/eula"},
            "links": [
                {"kind": "homepage", "url": "https://example.com/starhopper"},
                {"kind": "support", "url": "https://example.com/support"}
            ],
            "requirements": {"arch": "x86_64", "min_ram_mb": 4096, "gpu_api": ["vulkan"], "installed_mb": 4800},
            "art": {
                "icon": "art/icon.png",
                "logo": "art/logo.webp",
                "hero": "art/hero.webp",
                "cover": "art/cover.webp",
                "screenshots": [{"file": "art/shot1.webp", "caption": {"en": "The first world"}}],
                "trailer": {"file": "art/trailer.webm", "poster": "art/trailer.webp"},
                "preview": "art/preview.webm"
            },
            "components": [{
                "id": "wine", "type": "wine", "source": "newest", "min": "9.0", "tested": "9.20",
                "bundled": {"path": "components/wine", "version": "9.20", "licence": "LGPL-2.1-or-later",
                            "source_url": "https://dl.winehq.org/wine/source/"}
            }],
            "run": {
                "runner": "wine",
                "component": "wine",
                "command": ["${payload}/StarHopper.exe", "-fullscreen"],
                "cwd": "${payload}",
                "env": {"WINEDLLOVERRIDES": "dinput8=n,b"},
                "launch_mode": "fullscreen",
                "prefix": {"arch": "win64", "template": "payload/prefix-template", "epoch": 1},
                "setup": [{"id": "vcredist", "command": ["${payload}/redist/vc_redist.x64.exe", "/q"], "once": true}],
                "discs": ["payload/disc1.iso"]
            },
            "permissions": {
                "network": false,
                "input": "controllers+keyboard-mouse",
                "multiarch": true,
                "reasons": {"multiarch": {"en": "The game is a 32-bit program."}}
            },
            "data": {"saves": ["prefix:drive_c/users/steamuser/Documents/Star Hopper"], "cache": ["data:shader-cache"]},
            "update": {"feed": "https://example.com/starhopper/feed.json", "channel": "stable"}
        });
        fx.files = vec![
            ("art/icon.png", &b"icon"[..]),
            ("art/logo.webp", b"logo"),
            ("art/hero.webp", b"hero"),
            ("art/cover.webp", b"cover"),
            ("art/shot1.webp", b"shot"),
            ("art/trailer.webm", b"trailer"),
            ("art/trailer.webp", b"poster"),
            ("art/preview.webm", b"preview"),
            ("payload/StarHopper.exe", b"MZ exe"),
            ("payload/redist/vc_redist.x64.exe", b"MZ redist"),
            ("payload/disc1.iso", b"disc image"),
            (
                "payload/prefix-template/drive_c/windows/system.ini",
                b"[boot]",
            ),
            ("components/wine/bin/wine", b"elf"),
            ("components/wine/lib/libwine.so.1.2.3", b"so"),
            ("licences/LGPL-2.1.txt", b"licence text"),
            ("README.txt", b"read me"),
        ]
        .into_iter()
        .map(|(p, d)| (p.to_string(), d.to_vec()))
        .collect();
        fx.exec = ["payload/StarHopper.exe", "components/wine/bin/wine"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        fx.dirs = vec!["payload/saves".into()];
        // A legal 3-hop chain: libwine.so -> libwine.so.1 -> libwine.so.1.2 -> libwine.so.1.2.3.
        fx.links = vec![
            (
                "components/wine/lib/libwine.so".into(),
                "libwine.so.1".into(),
            ),
            (
                "components/wine/lib/libwine.so.1".into(),
                "libwine.so.1.2".into(),
            ),
            (
                "components/wine/lib/libwine.so.1.2".into(),
                "libwine.so.1.2.3".into(),
            ),
        ];
        fx
    }

    /// [`Fx::wine_full`] whose bundled Wine carries `runner_json` (and the `bin/wineserver` its
    /// default entry names).
    pub fn wine_with_runner(runner_json: &[u8]) -> Fx {
        let mut fx = Fx::wine_full();
        fx.file("components/wine/bin/wineserver", b"elf");
        fx.file("components/wine/runner.json", runner_json);
        fx
    }

    pub fn file(&mut self, path: &str, data: &[u8]) -> &mut Self {
        self.files.push((path.to_string(), data.to_vec()));
        self
    }

    /// The text of `play.files` for the current contents (sorted bytewise).
    pub fn table(&self) -> Vec<u8> {
        if let Some(t) = &self.table_override {
            return t.clone();
        }
        let q = |s: &str| serde_json::to_string(s).unwrap();
        let mut lines: Vec<(String, String)> = Vec::new();
        for (p, d) in &self.files {
            let x = if self.exec.contains(p) {
                ",\"x\":1"
            } else {
                ""
            };
            lines.push((
                p.clone(),
                format!(
                    "{{\"h\":\"{}\",\"p\":{},\"s\":{},\"t\":\"f\"{x}}}",
                    sha_hex(d),
                    q(p),
                    d.len()
                ),
            ));
        }
        for d in &self.dirs {
            lines.push((d.clone(), format!("{{\"p\":{},\"t\":\"d\"}}", q(d))));
        }
        for (p, to) in &self.links {
            lines.push((
                p.clone(),
                format!("{{\"p\":{},\"t\":\"l\",\"to\":{}}}", q(p), q(to)),
            ));
        }
        lines.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
        let mut out = String::new();
        for (_, v) in lines {
            out.push_str(&v);
            out.push('\n');
        }
        out.into_bytes()
    }

    pub fn manifest_bytes(&self) -> Vec<u8> {
        self.manifest_override
            .clone()
            .unwrap_or_else(|| serde_json::to_vec_pretty(&self.manifest).unwrap())
    }

    pub fn mem(&self) -> MemorySource {
        let mut m = MemorySource::new();
        m.add_file("play.json", self.manifest_bytes());
        m.add_file("play.files", self.table());
        for (p, d) in &self.files {
            m.add_file(p, d.clone());
        }
        for d in &self.dirs {
            m.add_dir(d);
        }
        m
    }

    /// Write the package as a folder under `root`.
    pub fn write_dir(&self, root: &Path) {
        let put = |p: &str, d: &[u8]| {
            let full = root.join(p);
            std::fs::create_dir_all(full.parent().unwrap()).unwrap();
            std::fs::write(full, d).unwrap();
        };
        put("play.json", &self.manifest_bytes());
        put("play.files", &self.table());
        for (p, d) in &self.files {
            put(p, d);
        }
        for d in &self.dirs {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
    }

    /// The zip entries for this package, ready for a test to adjust.
    pub fn zip_entries(&self) -> Vec<ZE> {
        let mut v = vec![
            ZE::file("play.json", self.manifest_bytes()),
            ZE::file("play.files", self.table()),
        ];
        for (p, d) in &self.files {
            v.push(ZE::file(p, d.clone()));
        }
        for d in &self.dirs {
            v.push(ZE::dir(d));
        }
        v
    }

    pub fn zip(&self) -> Vec<u8> {
        write_zip(&self.zip_entries())
    }
}

/// A valid `runner.json` for [`Fx::wine_full`]'s bundled Wine, with every optional key.
pub fn wine_runner_json() -> Value {
    json!({
        "format": 1,
        "family": "wine",
        "kind": "wine",
        "version": "9.20",
        "arch": "x86_64",
        "entry": {"wine": "bin/wine", "wineserver": "bin/wineserver"},
        "capabilities": ["multiarch", "dxvk"],
        "licence": "LGPL-2.1-or-later",
        "source_url": "https://dl.winehq.org/wine/source/"
    })
}

/// Validate a package value.
pub fn check(fx: &Fx) -> Result<Package, Vec<Problem>> {
    validate(&fx.mem(), &ValidateOptions::default())
}

pub fn check_zip(bytes: Vec<u8>) -> Result<Package, Vec<Problem>> {
    let src = ZipSource::new(Cursor::new(bytes))?;
    validate(&src, &ValidateOptions::default())
}

pub fn codes_of(r: &Result<Package, Vec<Problem>>) -> Vec<String> {
    match r {
        Ok(_) => vec![],
        Err(p) => p.iter().map(|p| p.code.clone()).collect(),
    }
}

/// Assert the result is a rejection that includes `code`.
#[track_caller]
pub fn assert_rejected(r: Result<Package, Vec<Problem>>, code: &str) {
    match r {
        Ok(_) => panic!("expected {code}, but the package was accepted"),
        Err(p) => assert!(
            p.iter().any(|x| x.code == code),
            "expected {code}, got {:#?}",
            p
        ),
    }
}

/// Assert the result is a rejection with `code` at `path`.
#[track_caller]
pub fn assert_rejected_at(r: Result<Package, Vec<Problem>>, code: &str, path: &str) {
    match r {
        Ok(_) => panic!("expected {code} at {path}, but the package was accepted"),
        Err(p) => assert!(
            p.iter().any(|x| x.code == code && x.path == path),
            "expected {code} at {path}, got {:#?}",
            p
        ),
    }
}

#[track_caller]
pub fn assert_valid(r: Result<Package, Vec<Problem>>) -> Package {
    match r {
        Ok(p) => p,
        Err(p) => panic!("expected a valid package, got {:#?}", p),
    }
}

// ----- zip writer ---------------------------------------------------------------------------

/// One entry of a zip to write, with every field a test may want to falsify.
#[derive(Clone)]
pub struct ZE {
    pub name: String,
    pub data: Vec<u8>,
    pub method: u16,
    pub flags: u16,
    pub made_by: u16,
    pub external: u32,
    pub crc: Option<u32>,
    pub declared_usize: Option<u64>,
    pub declared_csize: Option<u64>,
    pub local_name: Option<String>,
    /// Not written: a second central entry that points at the entry with this index.
    pub alias_of: Option<usize>,
    pub precompressed: Option<Vec<u8>>,
    /// Raw bytes written before this entry's local header.
    pub pad_before: Vec<u8>,
    /// The offset the central directory claims for this entry.
    pub cd_offset: Option<u64>,
    /// Raw name bytes for both headers (to write a name that is not UTF-8).
    pub name_bytes: Option<Vec<u8>>,
    /// Raw extra field bytes for the central directory entry.
    pub cd_extra: Vec<u8>,
    /// The CRC the data descriptor carries (default: the right one).
    pub descriptor_crc: Option<u32>,
}

impl ZE {
    pub fn file(name: &str, data: Vec<u8>) -> ZE {
        ZE {
            name: name.to_string(),
            data,
            method: 0,
            flags: 0,
            made_by: 0x0314,
            external: 0o100644 << 16,
            crc: None,
            declared_usize: None,
            declared_csize: None,
            local_name: None,
            alias_of: None,
            precompressed: None,
            pad_before: vec![],
            cd_offset: None,
            name_bytes: None,
            cd_extra: vec![],
            descriptor_crc: None,
        }
    }

    pub fn dir(name: &str) -> ZE {
        let mut z = ZE::file(&format!("{name}/"), vec![]);
        z.external = 0o040755 << 16;
        z
    }

    pub fn deflated(mut self) -> ZE {
        self.method = 8;
        self
    }

    pub fn mode(mut self, mode: u32) -> ZE {
        self.external = mode << 16;
        self
    }
}

fn crc32(data: &[u8]) -> u32 {
    let mut c = flate2::Crc::new();
    c.update(data);
    c.sum()
}

fn deflate(data: &[u8]) -> Vec<u8> {
    let mut e = DeflateEncoder::new(Vec::new(), Compression::default());
    e.write_all(data).unwrap();
    e.finish().unwrap()
}

pub fn write_zip(entries: &[ZE]) -> Vec<u8> {
    write_zip_opts(entries, false)
}

/// `zip64` writes the ZIP64 end records, with the plain end record saturated.
pub fn write_zip_opts(entries: &[ZE], zip64: bool) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    struct Cd {
        e: ZE,
        offset: u64,
        csize: u64,
        usize_: u64,
        crc: u32,
    }
    let mut cds: Vec<Cd> = Vec::new();
    let mut offsets: Vec<u64> = Vec::new();
    for (i, e) in entries.iter().enumerate() {
        if let Some(target) = e.alias_of {
            let (offset, csize, usize_, crc) = {
                let t = &cds[target];
                (t.offset, t.csize, t.usize_, t.crc)
            };
            cds.push(Cd {
                e: e.clone(),
                offset,
                csize,
                usize_,
                crc,
            });
            offsets.push(offset);
            continue;
        }
        let stored = match (&e.precompressed, e.method) {
            (Some(p), _) => p.clone(),
            (None, 8) => deflate(&e.data),
            _ => e.data.clone(),
        };
        let crc = e.crc.unwrap_or_else(|| crc32(&e.data));
        let csize = e.declared_csize.unwrap_or(stored.len() as u64);
        let usize_ = e.declared_usize.unwrap_or(e.data.len() as u64);
        out.extend(&e.pad_before);
        let offset = out.len() as u64;
        let name = e.local_name.clone().unwrap_or_else(|| e.name.clone());
        let name_bytes = e
            .name_bytes
            .clone()
            .unwrap_or_else(|| name.as_bytes().to_vec());
        let descriptor = e.flags & 8 != 0;
        let (l_crc, l_csize, l_usize) = if descriptor {
            (0, 0, 0)
        } else {
            (crc, csize, usize_)
        };
        out.extend(0x0403_4b50u32.to_le_bytes());
        out.extend(20u16.to_le_bytes());
        out.extend(e.flags.to_le_bytes());
        out.extend(e.method.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(0x21u16.to_le_bytes());
        out.extend(l_crc.to_le_bytes());
        out.extend((l_csize as u32).to_le_bytes());
        out.extend((l_usize as u32).to_le_bytes());
        out.extend((name_bytes.len() as u16).to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(&name_bytes);
        out.extend(&stored);
        if descriptor {
            out.extend(0x0807_4b50u32.to_le_bytes());
            out.extend(e.descriptor_crc.unwrap_or(crc).to_le_bytes());
            out.extend((csize as u32).to_le_bytes());
            out.extend((usize_ as u32).to_le_bytes());
        }
        offsets.push(offset);
        cds.push(Cd {
            e: e.clone(),
            offset,
            csize,
            usize_,
            crc,
        });
        let _ = i;
    }
    let cd_start = out.len() as u64;
    for c in &cds {
        out.extend(0x0201_4b50u32.to_le_bytes());
        out.extend(c.e.made_by.to_le_bytes());
        out.extend(20u16.to_le_bytes());
        out.extend(c.e.flags.to_le_bytes());
        out.extend(c.e.method.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(0x21u16.to_le_bytes());
        out.extend(c.crc.to_le_bytes());
        out.extend((c.csize as u32).to_le_bytes());
        out.extend((c.usize_ as u32).to_le_bytes());
        let name_bytes =
            c.e.name_bytes
                .clone()
                .unwrap_or_else(|| c.e.name.as_bytes().to_vec());
        out.extend((name_bytes.len() as u16).to_le_bytes());
        out.extend((c.e.cd_extra.len() as u16).to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(0u16.to_le_bytes());
        out.extend(c.e.external.to_le_bytes());
        out.extend((c.e.cd_offset.unwrap_or(c.offset) as u32).to_le_bytes());
        out.extend(&name_bytes);
        out.extend(&c.e.cd_extra);
    }
    let cd_size = out.len() as u64 - cd_start;
    if zip64 {
        let rec_off = out.len() as u64;
        out.extend(0x0606_4b50u32.to_le_bytes());
        out.extend(44u64.to_le_bytes());
        out.extend(45u16.to_le_bytes());
        out.extend(45u16.to_le_bytes());
        out.extend(0u32.to_le_bytes());
        out.extend(0u32.to_le_bytes());
        out.extend((cds.len() as u64).to_le_bytes());
        out.extend((cds.len() as u64).to_le_bytes());
        out.extend(cd_size.to_le_bytes());
        out.extend(cd_start.to_le_bytes());
        out.extend(0x0706_4b50u32.to_le_bytes());
        out.extend(0u32.to_le_bytes());
        out.extend(rec_off.to_le_bytes());
        out.extend(1u32.to_le_bytes());
    }
    let (count, size, start) = if zip64 {
        (0xFFFFu16, 0xFFFF_FFFFu32, 0xFFFF_FFFFu32)
    } else {
        (cds.len() as u16, cd_size as u32, cd_start as u32)
    };
    out.extend(0x0605_4b50u32.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    out.extend(count.to_le_bytes());
    out.extend(count.to_le_bytes());
    out.extend(size.to_le_bytes());
    out.extend(start.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    out
}

/// Entries of a source, for assertions.
pub fn listing(src: &dyn Source) -> Vec<(String, EntryKind, u64)> {
    let mut v: Vec<_> = src
        .entries()
        .unwrap()
        .into_iter()
        .map(|e| (e.path, e.kind, e.size))
        .collect();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v
}
