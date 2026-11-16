//! Who may Post and Withdraw: root and the shell's own user (`ruya-shell`), and nobody else. The
//! bus policy already allows only those two to call the service; this check is defence in depth.

/// The shell's Unix user. Its uid is looked up by name, never assumed.
pub const SHELL_USER: &str = "ruya-shell";

/// Is a caller with this uid allowed to post? `shell_uid` is `None` when the shell's user could
/// not be found: then only root is.
pub fn allowed(uid: u32, shell_uid: Option<u32>) -> bool {
    uid == 0 || shell_uid == Some(uid)
}

/// The uid of a Unix user, `None` when there is no such user or the database cannot be asked.
#[cfg(target_os = "linux")]
pub fn uid_of(name: &str) -> Option<u32> {
    let name = std::ffi::CString::new(name).ok()?;
    let mut buf = vec![0 as libc::c_char; 4096];
    // SAFETY: an all-zero `passwd` is a valid value for getpwnam_r to fill in.
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
    let rc = unsafe {
        libc::getpwnam_r(
            name.as_ptr(),
            &mut pwd,
            buf.as_mut_ptr(),
            buf.len(),
            &mut result,
        )
    };
    (rc == 0 && !result.is_null()).then_some(pwd.pw_uid)
}

/// Off Linux there are no Unix users: only root (uid 0) would pass, and dev mode lets everyone.
#[cfg(not(target_os = "linux"))]
pub fn uid_of(_name: &str) -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_and_the_shell_only() {
        assert!(allowed(0, Some(990)));
        assert!(allowed(990, Some(990)));
        assert!(!allowed(65534, Some(990)), "nobody");
        assert!(!allowed(1001, Some(990)), "a profile user");
    }

    #[test]
    fn without_the_shells_uid_only_root() {
        assert!(allowed(0, None));
        assert!(!allowed(990, None));
    }
}
