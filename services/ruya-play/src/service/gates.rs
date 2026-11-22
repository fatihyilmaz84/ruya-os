//! The D-Bus side's own checks (RUY-829; Play1.xml's header, 05 §7.3 step 1), pure so they run on
//! every host: who may vouch for an admin, which paths may be opened at all, and whether the drive
//! under a path is mounted the way `ruya-devices` mounts it.

use std::path::{Component, Path, PathBuf};

/// The shell's Unix user, and its private group of the same name.
pub const SHELL_USER: &str = "ruya-shell";

/// The id of `name` in an `/etc/passwd` text (`name:x:uid:gid:...`: the uid) or an `/etc/group` text
/// (`name:x:gid:members`: the gid), `None` when absent or not a number.
pub fn id_in_db(db: &str, name: &str) -> Option<u32> {
    db.lines().find_map(|line| {
        let mut f = line.split(':');
        if f.next()? != name {
            return None;
        }
        f.next()?;
        f.next()?.parse().ok()
    })
}

/// Whether `options.admin_approved` counts (Play1.xml, the trust boundary): only when the caller is
/// root or the shell. Unknown callers fail closed. `everyone` is the `--session` development mode,
/// where there is no ruya-shell user.
pub fn admin_counts(
    approved: bool,
    caller: Option<u32>,
    shell: Option<u32>,
    everyone: bool,
) -> bool {
    if !approved {
        return false;
    }
    if everyone {
        return true;
    }
    match caller {
        Some(0) => true,
        Some(uid) => shell == Some(uid),
        None => false,
    }
}

/// `path` with no `..` part (Rust's components already fold `.` and doubled slashes), from the root: the only form a source path takes (a
/// root is enough, so the console's paths read the same in the host tests).
pub fn is_plain_absolute(path: &Path) -> bool {
    path.has_root()
        && path.components().all(|c| {
            matches!(
                c,
                Component::RootDir | Component::Normal(_) | Component::Prefix(_)
            )
        })
        && path
            .to_str()
            .is_some_and(|s| !s.chars().any(char::is_control))
}

/// May `path` be opened? Exactly one of the `candidates` `ListSources` would list now, or a file
/// directly in `incoming` (a download). Compared as written: no link is resolved (the root service
/// does not look inside the drive here).
pub fn source_allowed(path: &Path, candidates: &[PathBuf], incoming: &Path) -> bool {
    if !is_plain_absolute(path) {
        return false;
    }
    if candidates.iter().any(|c| c.as_path() == path) {
        return true;
    }
    path.parent() == Some(incoming) && path.file_name().is_some()
}

/// One line of `/proc/self/mountinfo`, the parts the checks need.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mount {
    /// Where it is mounted (octal escapes decoded).
    pub point: PathBuf,
    /// The per-mount options (`rw,nosuid,nodev,noexec,relatime`).
    pub options: Vec<String>,
    /// The filesystem type.
    pub fstype: String,
    /// The mount source (`/dev/sdb1`).
    pub source: String,
}

impl Mount {
    /// Mounted `nosuid,nodev,noexec` (05 §7.3 step 1; `ruya-devices` always mounts so).
    pub fn is_safe(&self) -> bool {
        ["nosuid", "nodev", "noexec"]
            .iter()
            .all(|want| self.options.iter().any(|o| o == want))
    }
}

/// `\040` and the other octal escapes the kernel writes for space, tab, newline and backslash.
fn unescape(field: &str) -> String {
    let b = field.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\'
            && i + 3 < b.len()
            && b[i + 1..i + 4].iter().all(|d| (b'0'..=b'7').contains(d))
        {
            let v = (b[i + 1] - b'0') * 64 + (b[i + 2] - b'0') * 8 + (b[i + 3] - b'0');
            out.push(v);
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Parse `/proc/self/mountinfo`: `id parent major:minor root point options [optional...] - fstype
/// source super-options`. Lines that do not have that shape are skipped.
pub fn parse_mountinfo(text: &str) -> Vec<Mount> {
    text.lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split(' ').collect();
            let sep = fields.iter().position(|f| *f == "-")?;
            if sep < 6 || fields.len() < sep + 3 {
                return None;
            }
            Some(Mount {
                point: PathBuf::from(unescape(fields[4])),
                options: fields[5].split(',').map(str::to_string).collect(),
                fstype: fields[sep + 1].to_string(),
                source: unescape(fields[sep + 2]),
            })
        })
        .collect()
}

/// The mount `path` lives on: the last listed mount whose point is `path` or a parent of it (the
/// kernel lists mounts in the order they were made, so a later one on the same point hides an
/// earlier one).
pub fn mount_of<'a>(mounts: &'a [Mount], path: &Path) -> Option<&'a Mount> {
    let mut best: Option<&Mount> = None;
    for m in mounts {
        if path.starts_with(&m.point) {
            let longer = match best {
                None => true,
                Some(b) => m.point.components().count() >= b.point.components().count(),
            };
            if longer {
                best = Some(m);
            }
        }
    }
    best
}

/// Is the drive under `path` mounted safely? Paths outside `/run/media` (`incoming/` on the
/// system's own `/var`) are not removable media and pass.
pub fn mount_is_safe_for(mounts: &[Mount], path: &Path) -> bool {
    if !path.starts_with(crate::service::sources::MEDIA_ROOT) {
        return true;
    }
    mount_of(mounts, path)
        .is_some_and(|m| m.point.starts_with(crate::service::sources::MEDIA_ROOT) && m.is_safe())
}

#[cfg(test)]
mod tests {
    use super::*;

    const GROUP: &str = "wheel:x:10:fy
ruya-shell:x:974:
";
    const PASSWD: &str = "root:x:0:0:root:/root:/bin/bash\nruya-shell:x:973:973:RuyaOS shell:/var/lib/ruya-shell:/usr/sbin/nologin\nbroken\n";

    #[test]
    fn the_shell_ids_come_from_passwd_and_group() {
        assert_eq!(id_in_db(GROUP, "ruya-shell"), Some(974));
        assert_eq!(id_in_db(GROUP, "ruya"), None);
        assert_eq!(id_in_db(GROUP, "wheel"), Some(10));
        assert_eq!(id_in_db(PASSWD, "ruya-shell"), Some(973));
        assert_eq!(id_in_db(PASSWD, "root"), Some(0));
        assert_eq!(id_in_db(PASSWD, "ruya-shel"), None);
        assert_eq!(
            id_in_db("ruya-shell:x:abc:1::/:/bin/sh", "ruya-shell"),
            None
        );
    }

    #[test]
    fn admin_approved_counts_only_from_root_or_the_shell() {
        let shell = Some(973);
        assert!(admin_counts(true, Some(0), shell, false));
        assert!(admin_counts(true, Some(973), shell, false));
        assert!(!admin_counts(true, Some(1000), shell, false));
        assert!(!admin_counts(true, None, shell, false));
        // No ruya-shell user: only root.
        assert!(!admin_counts(true, Some(973), None, false));
        assert!(admin_counts(true, Some(0), None, false));
        // Without the option nobody is an admin, root included.
        assert!(!admin_counts(false, Some(0), shell, false));
        // Development: any caller of the session bus.
        assert!(admin_counts(true, Some(1000), None, true));
        assert!(!admin_counts(false, Some(1000), None, true));
    }

    #[test]
    fn only_listed_candidates_and_downloads_may_be_opened() {
        let incoming = Path::new("/var/lib/ruya-play/incoming");
        let cands = vec![
            PathBuf::from("/run/media/ruya-shell/USB/game.play.zip"),
            PathBuf::from("/run/media/ruya-shell/USB/Folder Game"),
        ];
        assert!(source_allowed(
            Path::new("/run/media/ruya-shell/USB/game.play.zip"),
            &cands,
            incoming
        ));
        assert!(source_allowed(
            Path::new("/run/media/ruya-shell/USB/Folder Game"),
            &cands,
            incoming
        ));
        assert!(source_allowed(
            Path::new("/var/lib/ruya-play/incoming/dl-1.play.zip"),
            &cands,
            incoming
        ));
        for bad in [
            "/run/media/ruya-shell/USB/other.play.zip",
            "/run/media/ruya-shell/USB/../USB/game.play.zip",
            "/var/lib/ruya-play/incoming/sub/dl.play.zip",
            "/var/lib/ruya-play/incoming/../trust.json",
            "/var/lib/ruya-play/incoming",
            "/etc/shadow",
            "relative.play.zip",
        ] {
            assert!(!source_allowed(Path::new(bad), &cands, incoming), "{bad}");
        }
    }

    const MOUNTINFO: &str = concat!(
        "22 1 253:0 / / rw,relatime shared:1 - xfs /dev/vda3 rw\n",
        "61 22 8:17 / /run/media/ruya-shell/MY\\040STICK rw,nosuid,nodev,noexec,relatime shared:30 - vfat /dev/sdb1 rw,uid=973\n",
        "62 22 8:33 / /run/media/ruya-shell/LOOSE rw,nosuid,relatime shared:31 - exfat /dev/sdc1 rw\n",
        "garbage line\n",
    );

    #[test]
    fn the_mount_flags_come_from_mountinfo() {
        let mounts = parse_mountinfo(MOUNTINFO);
        assert_eq!(mounts.len(), 3);
        assert_eq!(mounts[1].point, Path::new("/run/media/ruya-shell/MY STICK"));
        assert_eq!(mounts[1].fstype, "vfat");
        assert_eq!(mounts[1].source, "/dev/sdb1");
        assert!(mounts[1].is_safe());
        assert!(!mounts[2].is_safe());
        let safe = Path::new("/run/media/ruya-shell/MY STICK/game.play.zip");
        let loose = Path::new("/run/media/ruya-shell/LOOSE/game.play.zip");
        assert_eq!(
            mount_of(&mounts, safe).map(|m| m.source.as_str()),
            Some("/dev/sdb1")
        );
        assert!(mount_is_safe_for(&mounts, safe));
        assert!(!mount_is_safe_for(&mounts, loose));
        // A folder under /run/media that is no mount of its own sits on / (not nosuid): refused.
        assert!(!mount_is_safe_for(
            &mounts,
            Path::new("/run/media/ruya-shell/x.play.zip")
        ));
        // A download in incoming/ is not removable media.
        assert!(mount_is_safe_for(
            &mounts,
            Path::new("/var/lib/ruya-play/incoming/a.play.zip")
        ));
        // A later mount on the same point hides the earlier one.
        let over = format!(
            "{MOUNTINFO}70 61 8:18 / /run/media/ruya-shell/MY\\040STICK rw,relatime - ext4 /dev/sdb2 rw\n"
        );
        assert!(!mount_is_safe_for(&parse_mountinfo(&over), safe));
    }
}
