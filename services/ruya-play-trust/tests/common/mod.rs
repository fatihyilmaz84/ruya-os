//! Packages and keys made at test time. No private key is in the repository: every key here is
//! generated when the test runs.
#![allow(dead_code)]

use ruya_play_format::sha256_hex;
use ruya_play_format::MemorySource;
use ruya_play_trust::time::parse_utc;
use ruya_play_trust::{
    countersign, generate_key, inspect, sign_package, Context, Inspection, MemoryTrustStore,
    Refusal, SecretKey, StoreKeys,
};
use serde_json::{json, Value};

/// 2026-11-17T12:00:00Z, the "now" of every test.
pub fn now() -> i64 {
    parse_utc("2026-11-17T12:00:00Z").unwrap()
}

pub fn key() -> SecretKey {
    generate_key().unwrap()
}

/// A small valid package that a test signs, countersigns or breaks.
#[derive(Clone)]
pub struct Pkg {
    pub manifest: Value,
    pub files: Vec<(String, Vec<u8>)>,
    pub play_sig: Option<Vec<u8>>,
    pub store_sig: Option<Vec<u8>>,
    /// Bytes put into the package instead of the ones signed (tampering after signing).
    pub manifest_after: Option<Vec<u8>>,
    pub table_after: Option<Vec<u8>>,
    pub files_after: Vec<(String, Vec<u8>)>,
}

impl Pkg {
    pub fn minimal() -> Pkg {
        Pkg {
            manifest: json!({
                "format": 1,
                "id": "com.example.mini",
                "name": {"en": "Mini"},
                "version": "1.0",
                "build": 7,
                "art": {"icon": "art/icon.png"},
                "run": {"runner": "native", "command": ["${payload}/game"]}
            }),
            files: vec![
                ("art/icon.png".into(), b"not really a png".to_vec()),
                ("payload/game".into(), b"#!/bin/sh\necho hi\n".to_vec()),
            ],
            play_sig: None,
            store_sig: None,
            manifest_after: None,
            table_after: None,
            files_after: vec![],
        }
    }

    pub fn with_permissions(mut self, perms: Value) -> Pkg {
        self.manifest["permissions"] = perms;
        self
    }

    pub fn with_id(mut self, id: &str) -> Pkg {
        self.manifest["id"] = json!(id);
        self
    }

    pub fn id(&self) -> String {
        self.manifest["id"].as_str().unwrap().to_string()
    }

    pub fn build(&self) -> u64 {
        self.manifest["build"].as_u64().unwrap()
    }

    pub fn manifest_bytes(&self) -> Vec<u8> {
        serde_json::to_vec_pretty(&self.manifest).unwrap()
    }

    pub fn table(&self) -> Vec<u8> {
        let mut lines: Vec<(String, String)> = self
            .files
            .iter()
            .map(|(p, d)| {
                (
                    p.clone(),
                    format!(
                        "{{\"h\":\"{}\",\"p\":{},\"s\":{},\"t\":\"f\"}}",
                        sha256_hex(d),
                        serde_json::to_string(p).unwrap(),
                        d.len()
                    ),
                )
            })
            .collect();
        lines.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
        lines
            .into_iter()
            .map(|(_, l)| l + "\n")
            .collect::<String>()
            .into_bytes()
    }

    /// Sign as `key` for the package's own id and build.
    pub fn signed(self, key: &SecretKey) -> Pkg {
        let (id, build) = (self.id(), self.build());
        self.signed_for(key, &id, build, &[])
    }

    /// Sign as `key`, carrying sealed rotations.
    pub fn signed_rotating(self, key: &SecretKey, rotations: &[&[u8]]) -> Pkg {
        let (id, build) = (self.id(), self.build());
        self.signed_for(key, &id, build, rotations)
    }

    /// Sign as `key`, naming `id` and `build` (which may be another package's).
    pub fn signed_for(mut self, key: &SecretKey, id: &str, build: u64, rotations: &[&[u8]]) -> Pkg {
        self.play_sig = Some(
            sign_package(
                key,
                id,
                build,
                &self.manifest_bytes(),
                &self.table(),
                now() - 3600,
                rotations,
            )
            .unwrap(),
        );
        self
    }

    /// Countersign the current `play.sig` with the store key.
    pub fn countersigned(mut self, store: &SecretKey) -> Pkg {
        let sig = self.play_sig.clone().expect("sign first");
        self.store_sig = Some(countersign(
            store,
            &self.id(),
            self.build(),
            &sig,
            now() - 60,
        ));
        self
    }

    pub fn mem(&self) -> MemorySource {
        let mut m = MemorySource::new();
        m.add_file(
            "play.json",
            self.manifest_after
                .clone()
                .unwrap_or_else(|| self.manifest_bytes()),
        );
        m.add_file(
            "play.files",
            self.table_after.clone().unwrap_or_else(|| self.table()),
        );
        if let Some(s) = &self.play_sig {
            m.add_file("play.sig", s.clone());
        }
        if let Some(s) = &self.store_sig {
            m.add_file("store.sig", s.clone());
        }
        for (p, d) in &self.files {
            let d = self
                .files_after
                .iter()
                .find(|(q, _)| q == p)
                .map_or(d.clone(), |(_, n)| n.clone());
            m.add_file(p, d);
        }
        m
    }
}

/// The console: a store key it pins and its trust records.
pub struct Console {
    pub store: SecretKey,
    pub store_keys: StoreKeys,
    pub trust: MemoryTrustStore,
}

impl Console {
    pub fn new() -> Console {
        let store = key();
        Console {
            store_keys: StoreKeys::new(vec![store.public()]),
            store,
            trust: MemoryTrustStore::new(),
        }
    }

    pub fn inspect(&self, pkg: &Pkg) -> Result<Inspection, Refusal> {
        inspect(
            &pkg.mem(),
            &Context {
                store_keys: &self.store_keys,
                trust: &self.trust,
                blocklist: ruya_play_trust::ListCheck::NotChecked,
                runner_hashes: &[],
                verify_content: true,
            },
        )
    }
}

/// The code of a refusal (the first problem's code).
pub fn code_of(r: &Result<Inspection, Refusal>) -> String {
    match r {
        Ok(_) => "ok".into(),
        Err(refusal) => refusal.problems()[0].code.clone(),
    }
}

/// Assert `r` is refused with exactly `code` (and nothing else for a trust refusal).
pub fn assert_refused(r: &Result<Inspection, Refusal>, code: &str) {
    match r {
        Ok(_) => panic!("expected {code}, the package was accepted"),
        Err(refusal) => {
            let codes: Vec<String> = refusal.problems().iter().map(|p| p.code.clone()).collect();
            assert!(
                codes.iter().any(|c| c == code),
                "expected {code}, got {codes:?}"
            );
        }
    }
}
