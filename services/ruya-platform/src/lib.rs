//! ruya-platform: the one door for sandboxed apps (`org.ruyaos.Platform1`, ADR-022 tier B).
//! Everything here but `dbus.rs` and the Linux readers in `procfs.rs` is pure and tested on any
//! host: who the caller is (`identity`), what the player allowed (`store`, `capabilities`), the
//! rate and size limits (`limits`), the gate every call passes (`door`), where capabilities plug
//! in (`registry`) and the first capability (`lifecycle`). `mock` is the developer mock's scenario
//! world and control interface (RUY-158: the `ruya-platform-mock` binary, never in the image).

pub mod capabilities;
pub mod dbus;
pub mod door;
pub mod identity;
pub mod lifecycle;
pub mod limits;
pub mod mock;
pub mod procfs;
pub mod registry;
pub mod status;
pub mod store;

pub use door::Platform;
pub use status::Status;
