//! The trust record (RUY-851, 05 §7.1): the commit writes `files/share/ruyaos/play/trust.json`
//! (format 1, tier, signer key id and name, store signature yes or no) from what the console
//! verified, never from the package; a package that ships its own is refused (`share/` is the
//! console's).

mod common;

use common::*;
use ruya_play::service::commit::{self, TRUST_RECORD_IN_APP};
use ruya_play::{CommitRequest, JobStatus};
use ruya_play_trust::TrustRecord;
use serde_json::json;
use std::path::Path;
use std::sync::{Arc, Mutex};

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_tree(&e.path(), &t);
        } else {
            std::fs::copy(e.path(), t).unwrap();
        }
    }
}

type Laid = Arc<Mutex<Vec<Result<String, String>>>>;

/// Install `setup`'s package; the fake commit lays out a copy of the staged job as the Flatpak
/// commit does and keeps the trust record it wrote (or the lay-out's error).
fn install_and_read(mut setup: Setup) -> (JobStatus, Vec<Result<String, String>>) {
    let laid: Laid = Arc::default();
    let l2 = laid.clone();
    let scratch = tempfile::tempdir().unwrap();
    let base = scratch.path().to_path_buf();
    setup.commit_hook = Some(Box::new(move |req: &CommitRequest<'_>| {
        let copy = base.join(req.job);
        copy_tree(req.tree.parent().unwrap(), &copy);
        let (tree, art, meta) = (copy.join("tree"), copy.join("art"), copy.join("meta"));
        let request = CommitRequest {
            job: req.job,
            tree: &tree,
            art: &art,
            meta: &meta,
            manifest: req.manifest,
            tier: req.tier,
            assessment: req.assessment,
            signatures: req.signatures,
        };
        let got = commit::lay_out(&request)
            .map(|app| {
                std::fs::read_to_string(app.join("files").join(TRUST_RECORD_IN_APP)).unwrap()
            })
            .map_err(|e| format!("{e:?}"));
        l2.lock().unwrap().push(got);
    }));
    let mut h = setup.build();
    let r = h.install();
    let got = laid.lock().unwrap().clone();
    (r.status, got)
}

fn with_developer() -> Fx {
    let mut fx = game();
    fx.manifest["developer"] = json!({"name": "Example Games"});
    fx
}

fn record(text: &str) -> serde_json::Value {
    serde_json::from_str(text).unwrap()
}

#[test]
fn a_developer_package_gets_its_key_and_name() {
    let (status, laid) = install_and_read(Setup::with(Pkg::signed(&with_developer())));
    assert_eq!(status, JobStatus::Ok);
    let text = laid[0].as_ref().unwrap();
    assert_eq!(
        record(text),
        json!({
            "format": 1,
            "tier": "developer",
            "signer_id": dev_key().public().key_id(),
            "signer_name": "Example Games",
            "store_signed": false
        })
    );
    // The keys in the documented order, one line.
    assert!(
        text.starts_with("{\"format\":1,\"tier\":\"developer\",\"signer_id\":"),
        "{text}"
    );
    assert!(text.ends_with("\"store_signed\":false}\n"), "{text}");
    assert_eq!(
        TrustRecord::parse(text.as_bytes()).unwrap().tier,
        "developer"
    );
}

#[test]
fn an_official_package_says_the_store_signed_it() {
    let pkg = Pkg::Signed(
        Box::new(Pkg::Mem(with_developer().mem())),
        Arc::new(dev_key()),
        Some(Arc::new(store_key())),
    );
    let (status, laid) = install_and_read(Setup::with(pkg));
    assert_eq!(status, JobStatus::Ok);
    let r = record(laid[0].as_ref().unwrap());
    assert_eq!(r["tier"], json!("official"));
    assert_eq!(r["store_signed"], json!(true));
    assert_eq!(r["signer_id"], json!(dev_key().public().key_id()));
}

#[test]
fn an_unsigned_package_has_no_signer() {
    let setup = Setup {
        developer_mode: true,
        ..Setup::with(Pkg::Mem(with_developer().mem()))
    };
    let (status, laid) = install_and_read(setup);
    assert_eq!(status, JobStatus::Ok);
    assert_eq!(
        record(laid[0].as_ref().unwrap()),
        json!({
            "format": 1,
            "tier": "unverified",
            "signer_id": null,
            "signer_name": null,
            "store_signed": false
        })
    );
}

#[test]
fn a_package_cannot_ship_its_own_record() {
    let mut fx = with_developer();
    fx.file(
        "share/ruyaos/play/trust.json",
        br#"{"format":1,"tier":"official","signer_id":null,"signer_name":"RuyaOS","store_signed":true}"#,
    );
    // Refused with the file table's check (RUY-870), so the layout is never reached.
    let (status, laid) = install_and_read(Setup::with(Pkg::signed(&fx)));
    assert_eq!(status, JobStatus::InvalidPackage);
    assert!(laid.is_empty(), "{laid:?}");
}

#[test]
fn a_reader_refuses_another_format_or_tier() {
    assert!(
        TrustRecord::parse(br#"{"format":2,"tier":"developer","store_signed":false}"#).is_none()
    );
    assert!(TrustRecord::parse(br#"{"format":1,"tier":"root","store_signed":false}"#).is_none());
    assert!(TrustRecord::parse(b"not json").is_none());
    let ok =
        TrustRecord::parse(br#"{"format":1,"tier":"unverified","store_signed":false}"#).unwrap();
    assert_eq!(ok.signer_id, None);
}
