//! `ListSources` (Play1, RUY-829): candidate packages on mounted removable drives, by name only
//! (05 §9.1: nothing is opened, run or mounted). A candidate is a `*.play.zip` file or a folder
//! that holds a `play.json`, at the top of a drive or one folder down. Only drives under
//! [`MEDIA_ROOT`] mounted `nosuid,nodev,noexec` are looked at; links are never followed.

use crate::service::gates::Mount;
use std::path::{Path, PathBuf};

/// Where udisks mounts removable drives.
pub const MEDIA_ROOT: &str = "/run/media";
/// The most entries read from one folder.
pub const MAX_ENTRIES: usize = 1024;
/// The most candidates listed for one drive.
pub const MAX_PER_DRIVE: usize = 256;

/// One candidate (Play1's source record).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// The drive's id: the udisks object path of its block device (Devices1's volume id).
    pub drive: String,
    /// The drive's name for display (its mount folder's name).
    pub drive_label: String,
    /// The package's path.
    pub path: PathBuf,
    /// Its file or folder name.
    pub name: String,
    /// `folder` or `zip`.
    pub kind: &'static str,
    /// Bytes on disk (a zip's size; 0 for a folder: not cheap to know).
    pub size: u64,
}

/// The udisks object path of a block device (`/dev/sdb1` ->
/// `/org/freedesktop/UDisks2/block_devices/sdb1`; every byte that is not a letter or digit
/// becomes `_xx`, as udisks writes it).
pub fn udisks_block_path(device: &str) -> Option<String> {
    let name = device.strip_prefix("/dev/")?;
    if name.is_empty() {
        return None;
    }
    let mut out = String::from("/org/freedesktop/UDisks2/block_devices/");
    for b in name.bytes() {
        if b.is_ascii_alphanumeric() {
            out.push(b as char);
        } else {
            out.push_str(&format!("_{b:02x}"));
        }
    }
    Some(out)
}

fn is_zip_name(name: &str) -> bool {
    name.len() > ".play.zip".len() && name.to_ascii_lowercase().ends_with(".play.zip")
}

/// The candidates in `dir` (and, with `deeper`, in its plain subfolders that are not packages).
fn scan(dir: &Path, deeper: bool, out: &mut Vec<(PathBuf, String, &'static str, u64)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut subdirs = Vec::new();
    for entry in entries.take(MAX_ENTRIES).flatten() {
        if out.len() >= MAX_PER_DRIVE {
            return;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        if name.starts_with('.') || name.chars().any(char::is_control) {
            continue;
        }
        let path = entry.path();
        // symlink_metadata: a link is neither a file nor a folder here.
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.is_file() && is_zip_name(&name) {
            out.push((path, name, "zip", meta.len()));
        } else if meta.is_dir() {
            let has_manifest =
                std::fs::symlink_metadata(path.join("play.json")).is_ok_and(|m| m.is_file());
            if has_manifest {
                out.push((path, name, "folder", 0));
            } else if deeper {
                subdirs.push(path);
            }
        }
    }
    for sub in subdirs {
        scan(&sub, false, out);
    }
}

/// The candidates on one mounted drive.
pub fn candidates_on(mount: &Mount) -> Vec<Candidate> {
    let Some(drive) = udisks_block_path(&mount.source) else {
        return Vec::new();
    };
    let label = mount
        .point
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();
    let mut found = Vec::new();
    scan(&mount.point, true, &mut found);
    found.sort();
    found
        .into_iter()
        .map(|(path, name, kind, size)| Candidate {
            drive: drive.clone(),
            drive_label: label.clone(),
            path,
            name,
            kind,
            size,
        })
        .collect()
}

/// The drives `ListSources` looks at: under [`MEDIA_ROOT`], mounted safely, each mount point once
/// (the last mount on a point is the one that is seen).
pub fn media_mounts(mounts: &[Mount]) -> Vec<Mount> {
    let mut out: Vec<Mount> = Vec::new();
    for m in mounts {
        if !m.point.starts_with(MEDIA_ROOT) || m.point == Path::new(MEDIA_ROOT) {
            continue;
        }
        out.retain(|o| o.point != m.point);
        out.push(m.clone());
    }
    out.retain(Mount::is_safe);
    out
}

/// Every candidate on every safe removable drive.
pub fn list(mounts: &[Mount]) -> Vec<Candidate> {
    media_mounts(mounts)
        .iter()
        .flat_map(candidates_on)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::service::gates::parse_mountinfo;

    #[test]
    fn the_drive_id_is_the_udisks_object_path() {
        assert_eq!(
            udisks_block_path("/dev/sdb1").as_deref(),
            Some("/org/freedesktop/UDisks2/block_devices/sdb1")
        );
        assert_eq!(
            udisks_block_path("/dev/dm-0").as_deref(),
            Some("/org/freedesktop/UDisks2/block_devices/dm_2d0")
        );
        assert_eq!(udisks_block_path("tmpfs"), None);
        assert_eq!(udisks_block_path("/dev/"), None);
    }

    #[test]
    fn only_safe_mounts_under_run_media_are_looked_at() {
        let mounts = parse_mountinfo(concat!(
            "22 1 253:0 / / rw - xfs /dev/vda3 rw\n",
            "61 22 8:17 / /run/media/ruya-shell/A rw,nosuid,nodev,noexec - vfat /dev/sdb1 rw\n",
            "62 22 8:33 / /run/media/ruya-shell/B rw,nosuid - exfat /dev/sdc1 rw\n",
            "63 22 8:49 / /mnt/C rw,nosuid,nodev,noexec - ext4 /dev/sdd1 rw\n",
            "64 61 8:18 / /run/media/ruya-shell/A rw,nosuid,nodev - ext4 /dev/sdb2 rw\n",
        ));
        // A is hidden by an unsafe mount on the same point; B is unsafe; C is not removable.
        assert!(media_mounts(&mounts).is_empty());
        let mounts = parse_mountinfo(
            "61 22 8:17 / /run/media/ruya-shell/A rw,nosuid,nodev,noexec - vfat /dev/sdb1 rw\n",
        );
        assert_eq!(media_mounts(&mounts).len(), 1);
    }

    #[test]
    fn candidates_are_zips_and_folders_with_a_manifest_by_name_only() {
        let root = tempfile::tempdir().unwrap();
        let p = root.path();
        std::fs::write(p.join("game.play.zip"), b"12345").unwrap();
        std::fs::write(p.join("notes.zip"), b"x").unwrap();
        std::fs::write(p.join(".hidden.play.zip"), b"x").unwrap();
        std::fs::create_dir(p.join("Folder Game")).unwrap();
        std::fs::write(p.join("Folder Game/play.json"), b"{").unwrap();
        std::fs::create_dir(p.join("Folder Game/inner")).unwrap();
        std::fs::write(p.join("Folder Game/inner/x.play.zip"), b"x").unwrap();
        std::fs::create_dir_all(p.join("Games/deep/deeper")).unwrap();
        std::fs::write(p.join("Games/two.PLAY.ZIP"), b"22").unwrap();
        std::fs::write(p.join("Games/deep/deeper/three.play.zip"), b"x").unwrap();
        std::fs::create_dir(p.join("empty")).unwrap();
        let mount = Mount {
            point: p.to_path_buf(),
            options: vec!["nosuid".into(), "nodev".into(), "noexec".into()],
            fstype: "vfat".into(),
            source: "/dev/sdb1".into(),
        };
        let found = candidates_on(&mount);
        let got: Vec<(String, &str, u64)> = found
            .iter()
            .map(|c| (c.name.clone(), c.kind, c.size))
            .collect();
        assert_eq!(
            got,
            vec![
                ("Folder Game".to_string(), "folder", 0),
                ("two.PLAY.ZIP".to_string(), "zip", 2),
                ("game.play.zip".to_string(), "zip", 5),
            ]
        );
        assert!(found
            .iter()
            .all(|c| c.drive == "/org/freedesktop/UDisks2/block_devices/sdb1"));
        assert_eq!(found[1].path, p.join("Games").join("two.PLAY.ZIP"));
    }
}
