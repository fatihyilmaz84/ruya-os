//! RUY-99 acceptance: every hostile fixture of RUY-92 fails the **full install** with the same
//! error code and leaves nothing in staging or the target.
//!
//! The fixtures are not copied: `build.rs` takes the format crate's `tests/hostile.rs` as it is
//! (every test function, unchanged) and this file supplies the `common` module it uses, with
//! `check`, `check_zip` and `validate` replaced by an install through the importer: queue the
//! package as an admin, run the job (inspect, build check, space, unpack, re-walk, revocation,
//! art, commit), and return the package of an `ok` job or the job's problem list. Every refusal is
//! then held to a directory snapshot: the staging root is empty, the commit target is empty and
//! the commit step never ran. An `ok` job leaves an empty staging root too.
//!
//! What differs from a real install, and why:
//! - packages are signed by the test developer key when their `play.json` names an ASCII id and a
//!   build, as a signer would (the others, such as a manifest that is not JSON, install unsigned in
//!   developer mode), and `validate(.., official: true)` also gets a `store.sig` by the pinned test store key:
//!   the format tests use options a package only gets from its signatures;
//! - the art step passes every slot without reading it: the fixtures carry placeholder bytes, not
//!   images (`ruya-play-art` vets real art in its own suite, and `install.rs` here runs it);
//! - `validate` with `verify_content: false` is a format option the importer does not have (it
//!   always hashes while it copies): that one test calls the format crate directly.

#[path = "common/mod.rs"]
mod harness;

mod common {
    pub use super::harness::fx::*;

    use super::harness::{dev_key, store_key, PassArt, Pkg, Setup};
    use ruya_play::JobStatus;
    use ruya_play_format::{EntryKind, MemorySource, Package, Problem, Source, ValidateOptions};
    use std::io::Read;
    use std::sync::Arc;

    fn install(pkg: Pkg) -> Result<Package, Vec<Problem>> {
        let mut setup = Setup::with(pkg);
        setup.art = Box::new(PassArt);
        setup.developer_mode = true;
        let mut h = setup.build();
        let r = h.install();
        assert_eq!(h.staging(), Vec::<String>::new(), "staging is not empty");
        if r.status == JobStatus::Ok {
            assert_eq!(h.commit.calls().len(), 1);
            Ok(r.inspection.expect("an ok job has its inspection").package)
        } else {
            h.assert_nothing_left();
            assert!(!r.problems.is_empty(), "{:?} without a problem", r.status);
            Err(r.problems)
        }
    }

    fn signed(inner: Pkg, official: bool) -> Pkg {
        let store = official.then(|| Arc::new(store_key()));
        Pkg::Signed(Box::new(inner), Arc::new(dev_key()), store)
    }

    /// A memory copy of `src` (listing, declared sizes and content), so it can be opened again.
    fn snapshot(src: &dyn Source) -> MemorySource {
        let mut m = MemorySource::new();
        for e in src.entries().expect("memory fixtures list") {
            match e.kind {
                EntryKind::File => {
                    let mut data = Vec::new();
                    match src.open(&e.path) {
                        Ok(mut r) => {
                            let _ = r.read_to_end(&mut data);
                            m.add_file_declaring(&e.path, e.size, data);
                        }
                        Err(_) => {
                            m.add_entry(&e.path, EntryKind::File);
                        }
                    }
                }
                EntryKind::Dir => {
                    m.add_dir(&e.path);
                }
                kind => {
                    m.add_entry(&e.path, kind);
                }
            }
        }
        m
    }

    pub fn check(fx: &Fx) -> Result<Package, Vec<Problem>> {
        install(signed(Pkg::Mem(fx.mem()), false))
    }

    pub fn check_zip(bytes: Vec<u8>) -> Result<Package, Vec<Problem>> {
        install(signed(Pkg::Zip(bytes), false))
    }

    pub fn validate(src: &dyn Source, opts: &ValidateOptions) -> Result<Package, Vec<Problem>> {
        if !opts.verify_content {
            return ruya_play_format::validate(src, opts);
        }
        install(signed(Pkg::Mem(snapshot(src)), opts.official))
    }
}

include!(concat!(env!("OUT_DIR"), "/hostile_cases.rs"));
