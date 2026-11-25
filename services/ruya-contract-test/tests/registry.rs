//! RUY-403: no contract file and no served interface slips by without a test.
//!
//! Every interface in `api/dbus/*.xml` is either served by a service crate that has a
//! `tests/contract.rs` naming its file, or listed in `NOT_SERVED` with the reason. Every
//! `org.ruyaos.*` interface a service crate serves (a zbus `interface` attribute, found by
//! `served_interface_names`) is in a contract file. A new server or a new contract file fails here
//! until it is registered.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use ruya_contract_test::{contract_dir, interface_names, served_interface_names};

/// Interfaces of the contract that no Rust service serves, with the reason. None today (Play1 is
/// served by ruya-play since RUY-829).
const NOT_SERVED: &[(&str, &str)] = &[];

fn services_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// Every `.rs` file under `dir`.
fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// The contract: interface name -> its file name.
fn contract() -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for entry in fs::read_dir(contract_dir()).expect("api/dbus").flatten() {
        let file = entry.file_name().to_string_lossy().into_owned();
        if !file.ends_with(".xml") {
            continue;
        }
        let xml = fs::read_to_string(entry.path()).expect("a contract file");
        for name in interface_names(&xml).unwrap_or_else(|e| panic!("{file}: {e}")) {
            map.insert(name, file.clone());
        }
    }
    map
}

/// What the service crates serve: interface name -> the crate that serves it.
fn served() -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for entry in fs::read_dir(services_dir()).expect("services").flatten() {
        let krate = entry.file_name().to_string_lossy().into_owned();
        let mut files = Vec::new();
        rust_files(&entry.path().join("src"), &mut files);
        for file in files {
            let text = fs::read_to_string(&file).expect("a source file");
            let names =
                served_interface_names(&text).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
            for name in names {
                if name.starts_with("org.ruyaos.") {
                    map.insert(name, krate.clone());
                }
            }
        }
    }
    map
}

#[test]
fn every_contract_interface_is_served_and_tested_or_listed_as_not_served() {
    let served = served();
    let mut problems = Vec::new();
    for (name, file) in contract() {
        if let Some((_, reason)) = NOT_SERVED.iter().find(|(n, _)| *n == name) {
            if let Some(krate) = served.get(&name) {
                problems.push(format!(
                    "{name} is listed as not served ({reason}) but {krate} serves it: \
                     give {krate} a tests/contract.rs and take it off NOT_SERVED"
                ));
            }
            continue;
        }
        let Some(krate) = served.get(&name) else {
            problems.push(format!(
                "{name} ({file}) is served by no service crate: add the server, or list it in \
                 NOT_SERVED with the reason"
            ));
            continue;
        };
        let test = services_dir().join(krate).join("tests").join("contract.rs");
        match fs::read_to_string(&test) {
            Ok(text) if text.contains(&file) => {}
            Ok(_) => problems.push(format!(
                "{} does not name {file}: {krate} serves {name} and must compare it",
                test.display()
            )),
            Err(_) => problems.push(format!(
                "{krate} serves {name} ({file}) but has no tests/contract.rs"
            )),
        }
    }
    assert!(problems.is_empty(), "\n{}", problems.join("\n"));
}

#[test]
fn every_served_ruyaos_interface_is_in_the_contract() {
    let contract = contract();
    let problems: Vec<String> = served()
        .into_iter()
        .filter(|(name, _)| !contract.contains_key(name))
        .map(|(name, krate)| format!("{krate} serves {name}, which is in no api/dbus file"))
        .collect();
    assert!(problems.is_empty(), "\n{}", problems.join("\n"));
}

#[test]
fn the_not_served_list_names_contract_interfaces() {
    let contract = contract();
    for (name, _) in NOT_SERVED {
        assert!(
            contract.contains_key(*name),
            "{name} is on NOT_SERVED but is in no api/dbus file"
        );
    }
}

/// A parser that read nothing would make every comparison pass: each real interface has members.
#[test]
fn every_contract_interface_parses_to_members() {
    for entry in fs::read_dir(contract_dir()).expect("api/dbus").flatten() {
        let file = entry.file_name().to_string_lossy().into_owned();
        if !file.ends_with(".xml") {
            continue;
        }
        let xml = fs::read_to_string(entry.path()).expect("a contract file");
        let parsed = ruya_contract_test::parse(&xml).unwrap_or_else(|e| panic!("{file}: {e}"));
        assert!(!parsed.is_empty(), "{file}: no interface");
        for (name, members) in parsed {
            assert!(
                members.keys().any(|k| k.starts_with("method ")),
                "{file}: {name} parsed with no method"
            );
        }
    }
}
