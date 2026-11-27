//! The service process itself (RUY-1130). Its mount namespace sees the PIN store, and so does
//! anyone who reaches it through `/proc/<pid>/root`: the kernel lets a root peer with the same
//! capabilities in (ptrace access mode read). A non-dumpable process is closed to every peer
//! without CAP_SYS_PTRACE, whatever its uid, so the service drops the attribute at start; the
//! kernel then writes no core dump of it either. It would not cover a child: `execve` makes a
//! process dumpable again. So ruya-profiles runs no program (ADR-049): its account work goes to the
//! `ruya-accounts` helper over a socket, and whether an id is taken is asked in-process
//! (`accounts.rs`); `scripts/lint-private-state.ps1` refuses an exec in `src/`. Since it runs as
//! its own user, a peer with CAP_SETUID (ruya-store) that takes the `ruya-profiles` uid meets this
//! attribute too: the same uid is not enough without CAP_SYS_PTRACE. The units that hold
//! CAP_SYS_PTRACE are the named exceptions in `image/security-baseline.json` `private_state` (`01`
//! section 3 item 11).

use std::io;

/// Makes this process non-dumpable: `/proc/<pid>/root`, `mem`, `environ` and the file
/// descriptors are closed to other processes without CAP_SYS_PTRACE, and it writes no core dump.
/// A no-op off Linux.
pub fn refuse_peer_access() -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        use rustix::process::{set_dumpable_behavior, DumpableBehavior};
        set_dumpable_behavior(DumpableBehavior::NotDumpable).map_err(io::Error::from)
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok(())
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use rustix::process::{dumpable_behavior, DumpableBehavior};

    #[test]
    fn the_process_is_not_dumpable_after_it() {
        refuse_peer_access().unwrap();
        assert_eq!(dumpable_behavior().unwrap(), DumpableBehavior::NotDumpable);
    }
}
