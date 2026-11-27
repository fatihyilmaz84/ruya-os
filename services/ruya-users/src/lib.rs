//! The system's user database as the services ask it (NSS: `getpwnam_r`, `getpwuid_r`,
//! `getgrgid_r`): the passwd record of a user name, the uid of a name, the name of a uid, and
//! whether a uid or a gid is taken. The one copy of these calls (RUY-1098): `ruya-session`,
//! `ruya-notifications`, `ruya-platform`, `ruya-profiles` and `ruya-accounts` use it (RUY-1264:
//! ruya-profiles runs no `getent`). Off Linux there are no Unix users: every lookup answers "no
//! such user".

/// The fields of a passwd record that the services read (`struct passwd`, password and shell
/// left out).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Passwd {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    /// The comment (GECOS) field.
    pub gecos: String,
    pub home: String,
}

/// The buffer the `_r` calls start with, and the most they get on `ERANGE` (a group with many
/// members needs more than a passwd line).
#[cfg(target_os = "linux")]
const FIRST_BUF: usize = 4096;
#[cfg(target_os = "linux")]
const MAX_BUF: usize = 1 << 20;

/// Runs a reentrant NSS lookup with a buffer that grows on `ERANGE`: `Ok(true)` when it found an
/// entry, `Ok(false)` for the documented "no such entry" answers, `Err(errno)` otherwise. `call`
/// gets the buffer and returns the call's result code and whether the result pointer was set.
#[cfg(target_os = "linux")]
fn nss_lookup(mut call: impl FnMut(&mut [libc::c_char]) -> (i32, bool)) -> Result<bool, i32> {
    let mut len = FIRST_BUF;
    loop {
        let mut buf = vec![0 as libc::c_char; len];
        match call(&mut buf) {
            (0, true) => return Ok(true),
            // The documented "no such entry" answers. EPERM read this way is harmless: profile
            // users are in /etc/passwd, which nothing here is denied (RUY-621).
            (0, false) | (libc::ENOENT | libc::ESRCH | libc::EBADF | libc::EPERM, _) => {
                return Ok(false)
            }
            (libc::ERANGE, _) if len < MAX_BUF => len *= 2,
            (err, _) => return Err(err),
        }
    }
}

/// A NUL-terminated C string field of a filled-in record (`None` for a null pointer).
#[cfg(target_os = "linux")]
fn c_field<'a>(ptr: *const libc::c_char) -> Option<&'a std::ffi::CStr> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the pointer is a field of a record getpwnam_r or getpwuid_r just filled in; it
    // points to a NUL-terminated string inside the buffer, which is alive while the caller reads
    // it (every caller copies it out at once).
    Some(unsafe { std::ffi::CStr::from_ptr(ptr) })
}

/// A field as UTF-8 (`None` for a null pointer or another encoding).
#[cfg(target_os = "linux")]
fn text(ptr: *const libc::c_char) -> Option<String> {
    c_field(ptr)?.to_str().ok().map(str::to_owned)
}

/// A field, another encoding read lossily ("" for a null pointer).
#[cfg(target_os = "linux")]
fn lossy_text(ptr: *const libc::c_char) -> String {
    c_field(ptr)
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// The passwd record of the user `name`: `Ok(None)` when the user database says there is no such
/// user, `Err` (the errno) when it could not be asked. A field in another encoding than UTF-8 is
/// read lossily, so the uid never depends on the comment's bytes (and a lossy comment never
/// equals a profile marker it does not hold).
#[cfg(target_os = "linux")]
pub fn passwd_of(name: &str) -> Result<Option<Passwd>, i32> {
    let Ok(cname) = std::ffi::CString::new(name) else {
        return Err(libc::EINVAL);
    };
    let mut record = None;
    let found = nss_lookup(|buf| {
        // SAFETY: an all-zero `passwd` is a valid value for getpwnam_r to fill in.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
        let rc = unsafe {
            libc::getpwnam_r(
                cname.as_ptr(),
                &mut pwd,
                buf.as_mut_ptr(),
                buf.len(),
                &mut result,
            )
        };
        if rc == 0 && !result.is_null() {
            // Read the strings now: they live in `buf`, which the next round replaces. A field in
            // another encoding is read lossily, so the uid never depends on the comment's bytes.
            record = Some(Passwd {
                name: lossy_text(pwd.pw_name),
                uid: pwd.pw_uid,
                gid: pwd.pw_gid,
                gecos: lossy_text(pwd.pw_gecos),
                home: lossy_text(pwd.pw_dir),
            });
        }
        (rc, !result.is_null())
    })?;
    Ok(if found { record } else { None })
}

/// Off Linux: no such user.
#[cfg(not(target_os = "linux"))]
pub fn passwd_of(_name: &str) -> Result<Option<Passwd>, i32> {
    Ok(None)
}

/// The uid of the user `name`: `Ok(None)` when the user database says there is no such user, `Err`
/// (the errno) when it could not be asked.
pub fn lookup_uid(name: &str) -> Result<Option<u32>, i32> {
    Ok(passwd_of(name)?.map(|p| p.uid))
}

/// The uid of the user `name`, `None` when there is no such user or the database cannot be asked.
pub fn uid_of(name: &str) -> Option<u32> {
    lookup_uid(name).ok().flatten()
}

/// `getpwuid_r` for `uid`: `Ok(Some(read(record)))` when a user has it, `Ok(None)` when none
/// does, `Err` (the errno) when the database could not be asked. `read` runs while the record's
/// strings are alive.
#[cfg(target_os = "linux")]
fn by_uid<T>(uid: u32, mut read: impl FnMut(&libc::passwd) -> T) -> Result<Option<T>, i32> {
    let mut out = None;
    let found = nss_lookup(|buf| {
        // SAFETY: an all-zero `passwd` is a valid value for getpwuid_r to fill in.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
        let rc =
            unsafe { libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result) };
        if rc == 0 && !result.is_null() {
            out = Some(read(&pwd));
        }
        (rc, !result.is_null())
    })?;
    Ok(if found { out } else { None })
}

/// The name of the user `uid`, `None` when there is none (or it is not UTF-8).
#[cfg(target_os = "linux")]
pub fn name_of(uid: u32) -> Option<String> {
    by_uid(uid, |pwd| text(pwd.pw_name))
        .ok()
        .flatten()
        .flatten()
}

/// Off Linux: no such user.
#[cfg(not(target_os = "linux"))]
pub fn name_of(_uid: u32) -> Option<String> {
    None
}

/// True when a user has the uid `uid`; `Err` (the errno) when the database could not be asked.
#[cfg(target_os = "linux")]
pub fn uid_in_use(uid: u32) -> Result<bool, i32> {
    Ok(by_uid(uid, |_| ())?.is_some())
}

/// Off Linux: no uid is taken.
#[cfg(not(target_os = "linux"))]
pub fn uid_in_use(_uid: u32) -> Result<bool, i32> {
    Ok(false)
}

/// True when a group has the gid `gid`; `Err` (the errno) when the database could not be asked.
#[cfg(target_os = "linux")]
pub fn gid_in_use(gid: u32) -> Result<bool, i32> {
    nss_lookup(|buf| {
        // SAFETY: an all-zero `group` is a valid value for getgrgid_r to fill in.
        let mut grp: libc::group = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::group = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and `buf.len()` is the buffer's real size.
        let rc =
            unsafe { libc::getgrgid_r(gid, &mut grp, buf.as_mut_ptr(), buf.len(), &mut result) };
        (rc, !result.is_null())
    })
}

/// Off Linux: no gid is taken.
#[cfg(not(target_os = "linux"))]
pub fn gid_in_use(_gid: u32) -> Result<bool, i32> {
    Ok(false)
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
        let root = passwd_of("root").unwrap().unwrap();
        assert_eq!((root.uid, root.gid, root.home.as_str()), (0, 0, "/root"));
        assert_eq!((uid_in_use(0), gid_in_use(0)), (Ok(true), Ok(true)));
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
        assert!(matches!(passwd_of("no such user here"), Ok(None)));
    }
}
