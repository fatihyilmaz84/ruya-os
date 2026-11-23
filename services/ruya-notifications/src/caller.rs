//! Who may Post and Withdraw: root and the shell's own user (`ruya-shell`), and nobody else. The
//! bus policy already allows only those two to call the service; this check is defence in depth.

pub use ruya_users::{root_or_shell as allowed, SHELL_USER};
