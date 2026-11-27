//! ruya-accounts: the privileged half of the profiles' Unix accounts (ADR-049, ADR-022 build
//! decision 4's pattern). `ruya-profiles` holds the PIN hashes, runs as its own user with no
//! capability and never runs a program; making and removing a profile's Unix user (`useradd`,
//! `loginctl terminate-user` and `disable-linger`, `userdel --remove`) needs root, so this helper
//! does it: socket-activated per request (`ruya-accounts.socket`, 0660 root:ruya-profiles), no bus
//! name, no network, and the PIN store hidden from it.
//!
//! The request is one line of a fixed grammar ([`wire`]): `create <id> regular`,
//! `create <id> guest <uid>`, `delete <id>`, `remove-guest <id> <uid>`. Ids follow the one profile
//! id rule, guest uids are in [`account::GUEST_UIDS`]; there are no paths and no free arguments.
//! The helper answers only the `ruya-profiles` user (`SO_PEERCRED`), and deletes only a user that
//! carries the profile marker ([`account::classify`]): never a system user such as `ruya-shell`.
//!
//! Everything here is pure and tested on every host: the grammar ([`wire`]), the user rules
//! ([`account`]) and the helper's steps over injected system calls ([`serve`]). The Linux socket
//! and the commands live in the binary (`main.rs`); the client is `ruya-profiles`' `accounts.rs`.

pub mod account;
pub mod serve;
pub mod wire;

pub use account::AccountKind;
pub use wire::{Code, Reply, Request};
