//! The pid a pidfd names, from this process's `/proc/self/fdinfo/<fd>` (`Pid:\t1234`; `-1` once the
//! process is gone, so a reused pid is seen). The door reads its own descriptor and the helper its
//! own copy of the same pidfd: neither trusts a pid the other sends.

/// The `Pid:` value of an fdinfo text, `None` without one (the descriptor is no pidfd).
pub fn fdinfo_pid(text: &str) -> Option<i32> {
    text.lines()
        .find_map(|l| l.strip_prefix("Pid:"))
        .and_then(|v| v.trim().parse().ok())
}

/// The fdinfo of a pidfd is a few hundred bytes.
#[cfg(target_os = "linux")]
const MAX_FDINFO: u64 = 4096;

/// The `Pid:` of this process's descriptor `fd`; `None` when it is no pidfd or cannot be read.
/// `/proc/self/fdinfo` is the kernel's folder, so the path to it is followed; the file itself is
/// read with a cap and never through a link (`ruya-fs`).
#[cfg(target_os = "linux")]
pub fn own_pidfd_pid(fd: i32) -> Option<i32> {
    use std::path::Path;
    let dir = ruya_fs::Dir::open(Path::new("/proc/self/fdinfo")).ok()?;
    let text = dir.read(Path::new(&fd.to_string()), MAX_FDINFO).ok()?;
    fdinfo_pid(std::str::from_utf8(&text).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fdinfo_lines() {
        assert_eq!(
            fdinfo_pid(
                "pos:\t0\nflags:\t02000002\nmnt_id:\t15\nino:\t1057\nPid:\t4242\nNSpid:\t4242\n"
            ),
            Some(4242)
        );
        assert_eq!(fdinfo_pid("Pid:\t-1\n"), Some(-1));
        assert_eq!(fdinfo_pid("pos:\t0\n"), None);
        assert_eq!(fdinfo_pid("Pid:\tx\n"), None);
    }
}
