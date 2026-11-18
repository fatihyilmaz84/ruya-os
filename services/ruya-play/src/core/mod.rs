//! The importer core: no D-Bus, no systemd, no Flatpak. Side effects go through the traits in
//! [`deps`]; [`fakes`] has the implementations the tests use.

pub mod art;
pub mod codes;
pub mod deps;
pub mod fakes;
pub mod helper;
pub mod importer;
pub mod installed;
pub mod jobs;
pub mod meta;
pub mod opener;
pub mod read_once;
pub mod reconcile;
pub mod staging;
pub mod status;
pub mod systemd_run;
pub mod unpack;
pub mod verify;
