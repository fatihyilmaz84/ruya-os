//! RUY-403 / RUY-829: the interface ruya-play serves is the one in api/dbus/org.ruyaos.Play1.xml.

mod common;

use common::*;
use ruya_contract_test::{assert_interfaces_are, assert_serves};
use ruya_play::dbus::PlayIface;
use ruya_play::service::Environment;
use std::sync::Arc;

struct NoSystem;

impl Environment for NoSystem {
    fn mountinfo(&self) -> String {
        String::new()
    }
    fn shell_uid(&self) -> Option<u32> {
        None
    }
}

#[test]
fn play1_matches_the_contract() {
    let Harness { root, importer, .. } = Setup::default().build();
    let (events, _receiver) = async_channel::unbounded();
    let iface = PlayIface::new(Arc::new(importer), Arc::new(NoSystem), events, false);
    assert_serves("org.ruyaos.Play1.xml", &iface, &[]);
    assert_interfaces_are("org.ruyaos.Play1.xml", &["org.ruyaos.Play1"]);
    drop(root);
}
