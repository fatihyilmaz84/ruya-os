//! ruya-platform-identify: the privileged half of the caller identity of `org.ruyaos.Platform1`
//! (ADR-022 build decision 4). `ruya-platform`, the door every sandbox talks to, holds no
//! capability; reading a sandboxed caller's `/proc/<pid>/root/.flatpak-info` (0600, owned by the
//! profile user) needs `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH`, so this helper does it, without
//! a bus or network, socket-activated per request (`ruya-platform-identify.socket`, root only).
//!
//! The door sends the caller's pidfd (`SCM_RIGHTS`) and the bus's `UnixUserID`; the helper takes the
//! pid from its own fdinfo of that pidfd, opens the caller's `.flatpak-info` (never through a link,
//! a regular file owned by that uid, else `not-owned` and nothing is read) and its `cgroup`, and
//! returns the bytes or an error code for each. It parses nothing: the rules (the keyfile, the
//! scope, the pid re-check) stay in the door's `identity.rs`.
//!
//! Everything here is pure and tested on every host: the wire codec ([`wire`]), the helper's steps
//! over injected kernel reads ([`serve`]) and the fdinfo parser ([`fdinfo`]). The Linux socket and
//! file reads live in the binary (`main.rs`) and in the door's `HelperProcfs`.

pub mod fdinfo;
pub mod serve;
pub mod wire;

pub use wire::{FileError, Files, Refusal, Reply, Request};
