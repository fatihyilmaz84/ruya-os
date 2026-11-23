//! The system's user database as the services ask it (NSS: `getpwnam_r`, `getpwuid_r`): the uid
//! of a user name and the name of a uid. The one copy of these calls (RUY-1098): `ruya-session`,
//! `ruya-notifications` and `ruya-platform` use it. Off Linux there are no Unix users: every
//! lookup answers "no such user".

/// The uid of the user `name`: `Ok(None)` when the user database says there is no such user, `Err`
/// (the errno) when it could not be asked.
#[cfg(target_os = "linux")]
pub fn lookup_uid(name: &str) -> Result<Option<u32>, i32> {
    let Ok(name) = std::ffi::CString::new(name) else {
        return Err(libc::EINVAL);
    };
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
    match rc {
        0 if !result.is_null() => Ok(Some(pwd.pw_uid)),
        // The documented "no such user" answers. EPERM read this way is harmless: profile users
        // are in /etc/passwd, which nothing here is denied (RUY-621).
        0 | libc::ENOENT | libc::ESRCH | libc::EBADF | libc::EPERM => Ok(None),
        err => Err(err),
    }
}

/// Off Linux: no such user.
#[cfg(not(target_os = "linux"))]
pub fn lookup_uid(_name: &str) -> Result<Option<u32>, i32> {
    Ok(None)
}

/// The uid of the user `name`, `None` when there is no such user or the database cannot be asked.
pub fn uid_of(name: &str) -> Option<u32> {
    lookup_uid(name).ok().flatten()
}

/// The name of the user `uid`, `None` when there is none (or it is not UTF-8).
#[cfg(target_os = "linux")]
pub fn name_of(uid: u32) -> Option<String> {
    let mut buf = vec![0 as libc::c_char; 4096];
    // SAFETY: an all-zero `passwd` is a valid value for getpwuid_r to fill in.
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
    let rc = unsafe { libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result) };
    if rc != 0 || result.is_null() || pwd.pw_name.is_null() {
        return None;
    }
    // SAFETY: on success `pw_name` points to a NUL-terminated string inside `buf`, alive here.
    let name = unsafe { std::ffi::CStr::from_ptr(pwd.pw_name) };
    name.to_str().ok().map(str::to_owned)
}

/// Off Linux: no such user.
#[cfg(not(target_os = "linux"))]
pub fn name_of(_uid: u32) -> Option<String> {
    None
}

/// The shell's Unix user. Its uid is looked up by name (`uid_of`), never assumed.
pub const SHELL_USER: &str = "ruya-shell";

/// The rule of a service whose callers are root and the shell only (the bus policy says the same;
/// the service checks again, defence in depth). `shell_uid` is `None` when the shell's user could
/// not be found: then only root.
pub fn root_or_shell(uid: u32, shell_uid: Option<u32>) -> bool {
    uid == 0 || shell_uid == Some(uid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn root_is_uid_0_both_ways() {
        assert_eq!(lookup_uid("root"), Ok(Some(0)));
        assert_eq!(name_of(0).as_deref(), Some("root"));
    }

    #[test]
    fn root_and_the_shell_only() {
        assert!(root_or_shell(0, Some(990)));
        assert!(root_or_shell(990, Some(990)));
        assert!(!root_or_shell(65534, Some(990)), "nobody");
        assert!(!root_or_shell(1001, Some(990)), "a profile user");
    }

    #[test]
    fn without_the_shells_uid_only_root() {
        assert!(root_or_shell(0, None));
        assert!(!root_or_shell(990, None));
    }

    #[test]
    fn a_name_that_cannot_be_a_user_is_none() {
        assert_eq!(uid_of("no such user here"), None);
        assert_eq!(uid_of("nul\0inside"), None);
    }
}
