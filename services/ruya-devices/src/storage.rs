//! Drives and volumes (org.ruyaos.Devices1.Storage, T-174). udisks2 knows every block device; the
//! rules here pick the volumes worth showing, decide which are mounted and how, and turn the
//! outcome into the contract's strings. Pure and tested on any host; the udisks2 side is
//! `udisks.rs`.
//!
//! Policy (CLAUDE.md: nothing auto-runs from removable media): a removable volume with a
//! filesystem we know is mounted once, when it first shows up, with `nosuid,nodev,noexec` and
//! read-write. Read-only was not chosen because people copy saves and screenshots onto a stick;
//! those three options already make sure nothing on it runs, gets privileges or acts as a device.
//! A filesystem we do not know is listed but never mounted.

use std::collections::HashSet;
use std::sync::{Mutex, MutexGuard};

/// Mount options for every volume this service mounts (udisks accepts exactly these from an
/// unprivileged caller).
pub const MOUNT_OPTIONS: &str = "nosuid,nodev,noexec";

/// Mount points of the running system itself. An internal volume mounted only there is the OS,
/// not something to show in Settings.
const SYSTEM_MOUNTS: &[&str] = &[
    "/",
    "/boot",
    "/boot/efi",
    "/efi",
    "/sysroot",
    "/var",
    "/home",
    "/etc",
    "/usr",
];

/// What udisks says about one block device that has a filesystem, plus the free space the
/// adapter read from its mount point.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawVolume {
    /// The udisks object path of the block device.
    pub id: String,
    /// The udisks object path of its drive; empty when it has none (loop devices, zram).
    pub drive: String,
    /// `IdLabel`.
    pub label: String,
    /// The drive's vendor and model, joined.
    pub model: String,
    /// `IdType`: "ext4", "vfat", "exfat", "ntfs", "btrfs", ...
    pub id_type: String,
    pub size_bytes: u64,
    /// Free bytes at the mount point; 0 when not mounted or unreadable.
    pub free_bytes: u64,
    /// `HintSystem` of the block device: udisks thinks it belongs to the machine.
    pub hint_system: bool,
    /// `HintIgnore`.
    pub hint_ignore: bool,
    /// The drive's `Removable` flag.
    pub drive_removable: bool,
    /// The drive's `ConnectionBus`: "usb", "sdio", "" ...
    pub bus: String,
    pub mount_points: Vec<String>,
    pub read_only: bool,
}

/// A listed volume (the contract's dictionary).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Volume {
    pub id: String,
    /// The udisks drive object the volume lives on; partitions of one stick share it.
    pub drive: String,
    pub label: String,
    pub filesystem: &'static str,
    pub size_bytes: i64,
    pub free_bytes: i64,
    pub removable: bool,
    pub mounted: bool,
    pub mount_point: String,
    pub read_only: bool,
}

/// The filesystem names of the contract; "unknown" is one we do not mount.
fn filesystem_of(id_type: &str) -> &'static str {
    match id_type {
        "ext4" => "ext4",
        "btrfs" => "btrfs",
        "exfat" => "exfat",
        "vfat" => "vfat",
        "ntfs" => "ntfs",
        _ => "unknown",
    }
}

/// USB sticks, SD cards (an SDIO bus) and drives whose media can be taken out, unless udisks
/// says the device belongs to the machine.
fn is_removable(raw: &RawVolume) -> bool {
    !raw.hint_system && (raw.drive_removable || raw.bus == "usb" || raw.bus == "sdio")
}

fn is_system_mount(point: &str) -> bool {
    SYSTEM_MOUNTS.contains(&point)
}

/// The listed form of a block device, or `None` when it is not for the shell: ignored by udisks,
/// without a drive, or an internal volume that is the OS itself or not mounted (we never mount
/// internal disks, so there is nothing to show).
pub fn classify(raw: &RawVolume) -> Option<Volume> {
    if raw.hint_ignore || raw.drive.is_empty() {
        return None;
    }
    let removable = is_removable(raw);
    let filesystem = filesystem_of(&raw.id_type);
    let mounted = !raw.mount_points.is_empty();
    if !removable {
        let outside_system = raw.mount_points.iter().any(|p| !is_system_mount(p));
        if filesystem == "unknown" || !outside_system {
            return None;
        }
    }
    let label = raw.label.trim();
    let model = raw.model.trim();
    let label = if !label.is_empty() {
        label
    } else if !model.is_empty() {
        model
    } else if removable {
        "USB drive"
    } else {
        "Internal drive"
    };
    Some(Volume {
        id: raw.id.clone(),
        drive: raw.drive.clone(),
        label: label.to_owned(),
        filesystem,
        size_bytes: i64::try_from(raw.size_bytes).unwrap_or(i64::MAX),
        free_bytes: if mounted {
            i64::try_from(raw.free_bytes).unwrap_or(i64::MAX)
        } else {
            0
        },
        removable,
        mounted,
        mount_point: raw.mount_points.first().cloned().unwrap_or_default(),
        read_only: raw.read_only,
    })
}

/// Internal volumes first, then removable ones; each group by id (a stable order).
pub fn listed(raws: &[RawVolume]) -> Vec<Volume> {
    let mut out: Vec<Volume> = raws.iter().filter_map(classify).collect();
    out.sort_by(|a, b| a.removable.cmp(&b.removable).then_with(|| a.id.cmp(&b.id)));
    out
}

/// Why an unmount did not happen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnmountError {
    /// Something still has a file open on the volume.
    Busy,
    Failed(String),
}

/// udisks2, as far as the core needs it. `udisks::UdisksClient` talks to the bus.
pub trait Udisks: Send + Sync {
    /// Every block device with a filesystem.
    fn volumes(&self) -> Result<Vec<RawVolume>, String>;
    /// Mounts with the given comma-separated options. Already mounted counts as success.
    fn mount(&self, id: &str, options: &str) -> Result<(), String>;
    fn unmount(&self, id: &str) -> Result<(), UnmountError>;
    /// Powers the drive of this volume off (or ejects its media when it cannot be powered off).
    fn power_off(&self, id: &str) -> Result<(), String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownVolume,
    Busy,
    Unsupported,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownVolume => "unknown-volume",
            Status::Busy => "busy",
            Status::Unsupported => "unsupported",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

/// What a refresh found, for the signals.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Changes {
    /// Removable volumes that appeared after the first successful read (hot-plug).
    pub added: Vec<String>,
    /// The list differs from the last one.
    pub changed: bool,
}

impl Changes {
    pub fn any(&self) -> bool {
        self.changed || !self.added.is_empty()
    }
}

#[derive(Default)]
struct State {
    list: Vec<Volume>,
    /// The first read succeeded: volumes seen from now on are hot-plugged.
    started: bool,
    /// Removable volumes with a supported filesystem that we have seen. A volume is mounted once,
    /// when first seen; after an eject or a manual unmount it stays as it is.
    seen: HashSet<String>,
}

pub struct Storage<U: Udisks> {
    udisks: U,
    state: Mutex<State>,
    /// Serialises refreshes and ejects, which both mount and unmount.
    ops: Mutex<()>,
}

impl<U: Udisks> Storage<U> {
    pub fn new(udisks: U) -> Self {
        Storage {
            udisks,
            state: Mutex::new(State::default()),
            ops: Mutex::new(()),
        }
    }

    fn state_lock(&self) -> MutexGuard<'_, State> {
        // A poisoned lock only means another call panicked; the state is plain data.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn ops_lock(&self) -> MutexGuard<'_, ()> {
        self.ops.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn list(&self) -> Vec<Volume> {
        self.state_lock().list.clone()
    }

    /// Reads udisks again, mounts the removable volumes seen for the first time and returns what
    /// changed. The mounting happens before the list is published, so a volume is announced
    /// already mounted.
    pub fn refresh(&self) -> Result<Changes, String> {
        let _ops = self.ops_lock();
        let mut raws = self.udisks.volumes()?;
        // Decide under the lock, mount after releasing it: a mount is a blocking D-Bus call and
        // ListVolumes must keep answering meanwhile.
        let to_mount: Vec<String> = {
            let mut state = self.state_lock();
            raws.iter()
                .filter_map(classify)
                .filter(|v| v.removable && v.filesystem != "unknown")
                .filter(|v| state.seen.insert(v.id.clone()) && !v.mounted)
                .map(|v| v.id)
                .collect()
        };
        let mut mounted_any = false;
        for id in &to_mount {
            match self.udisks.mount(id, MOUNT_OPTIONS) {
                Ok(()) => mounted_any = true,
                Err(err) => eprintln!("ruya-devices: mounting {id} failed: {err}"),
            }
        }
        if mounted_any {
            if let Ok(again) = self.udisks.volumes() {
                raws = again;
            }
        }
        let now = listed(&raws);
        let mut state = self.state_lock();
        let present: HashSet<&str> = now.iter().map(|v| v.id.as_str()).collect();
        state.seen.retain(|id| present.contains(id.as_str()));
        let added = if state.started {
            now.iter()
                .filter(|v| v.removable && !state.list.iter().any(|old| old.id == v.id))
                .map(|v| v.id.clone())
                .collect()
        } else {
            Vec::new()
        };
        let changed = state.list != now;
        state.list = now;
        state.started = true;
        Ok(Changes { added, changed })
    }

    /// Unmounts the volume (and the other mounted partitions of its drive, which go away with
    /// it) and powers the drive off.
    pub fn eject(&self, id: &str) -> Status {
        if id.is_empty() {
            return Status::Invalid;
        }
        let _ops = self.ops_lock();
        let Ok(raws) = self.udisks.volumes() else {
            return Status::Failed;
        };
        let Some(target) = raws.iter().find(|r| r.id == id) else {
            return Status::UnknownVolume;
        };
        let Some(volume) = classify(target) else {
            return Status::UnknownVolume;
        };
        if !volume.removable {
            return Status::Failed;
        }
        if volume.filesystem == "unknown" {
            return Status::Unsupported;
        }
        let drive = target.drive.clone();
        let mounted: Vec<&RawVolume> = raws
            .iter()
            .filter(|r| r.drive == drive && !r.mount_points.is_empty())
            .collect();
        {
            // Whatever happens next, the refresh that follows must not mount them again.
            let mut state = self.state_lock();
            for r in &mounted {
                state.seen.insert(r.id.clone());
            }
        }
        let mut done: Vec<&str> = Vec::new();
        for r in &mounted {
            match self.udisks.unmount(&r.id) {
                Ok(()) => done.push(&r.id),
                Err(err) => {
                    // Back to how it was: what we unmounted comes back.
                    for id in done {
                        if let Err(e) = self.udisks.mount(id, MOUNT_OPTIONS) {
                            eprintln!("ruya-devices: mounting {id} again failed: {e}");
                        }
                    }
                    return match err {
                        UnmountError::Busy => Status::Busy,
                        UnmountError::Failed(why) => {
                            eprintln!("ruya-devices: unmounting {} failed: {why}", r.id);
                            Status::Failed
                        }
                    };
                }
            }
        }
        match self.udisks.power_off(id) {
            Ok(()) => Status::Ok,
            Err(err) => {
                eprintln!("ruya-devices: powering {id} off failed: {err}");
                Status::Failed
            }
        }
    }
}

/// A scripted udisks for tests and `--session` development: mounting and unmounting change the
/// scripted volumes, powering off removes the whole drive.
#[derive(Default)]
pub struct FakeUdisks {
    inner: Mutex<FakeInner>,
}

#[derive(Default)]
struct FakeInner {
    volumes: Vec<RawVolume>,
    /// Ids that refuse to unmount (a file is open).
    busy: HashSet<String>,
    /// Ids that refuse to mount.
    unmountable: HashSet<String>,
    /// Calls, in order: "mount:id:options", "unmount:id", "power-off:id".
    calls: Vec<String>,
}

impl FakeUdisks {
    pub fn new(volumes: Vec<RawVolume>) -> Self {
        let fake = FakeUdisks::default();
        fake.set(volumes);
        fake
    }

    fn inner(&self) -> MutexGuard<'_, FakeInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set(&self, volumes: Vec<RawVolume>) {
        self.inner().volumes = volumes;
    }

    pub fn plug(&self, volume: RawVolume) {
        self.inner().volumes.push(volume);
    }

    pub fn set_busy(&self, id: &str, busy: bool) {
        let mut inner = self.inner();
        if busy {
            inner.busy.insert(id.to_owned());
        } else {
            inner.busy.remove(id);
        }
    }

    pub fn refuse_mount(&self, id: &str) {
        self.inner().unmountable.insert(id.to_owned());
    }

    pub fn calls(&self) -> Vec<String> {
        self.inner().calls.clone()
    }
}

impl Udisks for FakeUdisks {
    fn volumes(&self) -> Result<Vec<RawVolume>, String> {
        Ok(self.inner().volumes.clone())
    }

    fn mount(&self, id: &str, options: &str) -> Result<(), String> {
        let mut inner = self.inner();
        inner.calls.push(format!("mount:{id}:{options}"));
        if inner.unmountable.contains(id) {
            return Err("cannot mount".to_owned());
        }
        let Some(v) = inner.volumes.iter_mut().find(|v| v.id == id) else {
            return Err("no such volume".to_owned());
        };
        if v.mount_points.is_empty() {
            v.mount_points = vec![format!("/run/media/ruya-shell/{}", v.label)];
            v.free_bytes = v.size_bytes / 2;
        }
        Ok(())
    }

    fn unmount(&self, id: &str) -> Result<(), UnmountError> {
        let mut inner = self.inner();
        inner.calls.push(format!("unmount:{id}"));
        if inner.busy.contains(id) {
            return Err(UnmountError::Busy);
        }
        match inner.volumes.iter_mut().find(|v| v.id == id) {
            Some(v) => {
                v.mount_points.clear();
                v.free_bytes = 0;
                Ok(())
            }
            None => Err(UnmountError::Failed("no such volume".to_owned())),
        }
    }

    fn power_off(&self, id: &str) -> Result<(), String> {
        let mut inner = self.inner();
        inner.calls.push(format!("power-off:{id}"));
        let drive = inner
            .volumes
            .iter()
            .find(|v| v.id == id)
            .map(|v| v.drive.clone())
            .ok_or_else(|| "no such volume".to_owned())?;
        inner.volumes.retain(|v| v.drive != drive);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(id: &str, drive: &str, fs: &str) -> RawVolume {
        RawVolume {
            id: id.to_owned(),
            drive: drive.to_owned(),
            label: String::new(),
            model: String::new(),
            id_type: fs.to_owned(),
            size_bytes: 8_000_000_000,
            free_bytes: 0,
            hint_system: false,
            hint_ignore: false,
            drive_removable: false,
            bus: "usb".to_owned(),
            mount_points: Vec::new(),
            read_only: false,
        }
    }

    fn stick(id: &str, drive: &str) -> RawVolume {
        RawVolume {
            label: "STICK".to_owned(),
            ..raw(id, drive, "exfat")
        }
    }

    fn internal(id: &str, fs: &str, mount: &str) -> RawVolume {
        RawVolume {
            hint_system: true,
            bus: "ata".to_owned(),
            mount_points: if mount.is_empty() {
                Vec::new()
            } else {
                vec![mount.to_owned()]
            },
            free_bytes: 5_000_000_000,
            ..raw(id, "/drive/sda", fs)
        }
    }

    // ---- classification

    #[test]
    fn a_usb_stick_is_removable_and_an_internal_disk_is_not() {
        let s = classify(&stick("/b/sdb1", "/d/sdb")).expect("listed");
        assert!(s.removable);
        assert_eq!(s.filesystem, "exfat");
        let d = classify(&internal("/b/sda3", "ext4", "/mnt/games")).expect("listed");
        assert!(!d.removable);
        assert_eq!(d.mount_point, "/mnt/games");
    }

    #[test]
    fn a_card_reader_and_a_drive_with_removable_media_are_removable() {
        let sd = RawVolume {
            bus: "sdio".to_owned(),
            ..stick("/b/mmcblk0p1", "/d/mmc")
        };
        assert!(classify(&sd).expect("listed").removable);
        let reader = RawVolume {
            bus: String::new(),
            drive_removable: true,
            ..stick("/b/sdc1", "/d/sdc")
        };
        assert!(classify(&reader).expect("listed").removable);
    }

    #[test]
    fn a_usb_disk_that_udisks_calls_system_is_internal() {
        let r = RawVolume {
            hint_system: true,
            mount_points: vec!["/mnt/data".to_owned()],
            ..stick("/b/sdb1", "/d/sdb")
        };
        assert!(!classify(&r).expect("listed").removable);
    }

    #[test]
    fn an_unknown_filesystem_is_listed_unmounted_as_unknown() {
        let v = classify(&raw("/b/sdb1", "/d/sdb", "f2fs")).expect("listed");
        assert_eq!(v.filesystem, "unknown");
        assert!(!v.mounted);
        assert_eq!(v.mount_point, "");
        assert_eq!(v.free_bytes, 0);
    }

    #[test]
    fn the_five_contract_filesystems_are_known() {
        for fs in ["ext4", "btrfs", "exfat", "vfat", "ntfs"] {
            assert_eq!(filesystem_of(fs), fs);
        }
        assert_eq!(filesystem_of("xfs"), "unknown");
        assert_eq!(filesystem_of("ext3"), "unknown");
    }

    #[test]
    fn the_os_itself_ignored_devices_and_drive_less_devices_are_not_listed() {
        assert!(classify(&internal("/b/sda2", "xfs", "/")).is_none());
        assert!(classify(&internal("/b/sda1", "vfat", "/boot/efi")).is_none());
        assert!(classify(&internal("/b/sda4", "ext4", "")).is_none());
        let ignored = RawVolume {
            hint_ignore: true,
            ..stick("/b/sdb1", "/d/sdb")
        };
        assert!(classify(&ignored).is_none());
        let loopdev = RawVolume {
            drive: String::new(),
            ..stick("/b/loop0", "")
        };
        assert!(classify(&loopdev).is_none());
    }

    #[test]
    fn free_space_is_reported_only_while_mounted() {
        let mut r = stick("/b/sdb1", "/d/sdb");
        r.free_bytes = 123;
        assert_eq!(classify(&r).expect("listed").free_bytes, 0);
        r.mount_points = vec!["/run/media/x/STICK".to_owned()];
        let v = classify(&r).expect("listed");
        assert!(v.mounted);
        assert_eq!(v.free_bytes, 123);
        assert_eq!(v.size_bytes, 8_000_000_000);
    }

    #[test]
    fn partitions_of_one_stick_share_the_drive_and_other_sticks_do_not() {
        let list = listed(&[
            stick("/b/sdb1", "/d/sdb"),
            stick("/b/sdb2", "/d/sdb"),
            raw("/b/sdb3", "/d/sdb", "f2fs"),
            stick("/b/sdc1", "/d/sdc"),
        ]);
        let drives: Vec<&str> = list.iter().map(|v| v.drive.as_str()).collect();
        assert_eq!(drives, ["/d/sdb", "/d/sdb", "/d/sdb", "/d/sdc"]);
    }

    #[test]
    fn the_label_falls_back_to_the_model_then_to_usb_drive() {
        let mut r = raw("/b/sdb1", "/d/sdb", "vfat");
        assert_eq!(classify(&r).expect("listed").label, "USB drive");
        r.model = " SanDisk Ultra ".to_owned();
        assert_eq!(classify(&r).expect("listed").label, "SanDisk Ultra");
        r.label = "  PHOTOS ".to_owned();
        assert_eq!(classify(&r).expect("listed").label, "PHOTOS");
    }

    #[test]
    fn internal_volumes_come_first_then_by_id() {
        let list = listed(&[
            stick("/b/sdc1", "/d/sdc"),
            stick("/b/sdb1", "/d/sdb"),
            internal("/b/sda3", "ext4", "/mnt/games"),
        ]);
        let ids: Vec<&str> = list.iter().map(|v| v.id.as_str()).collect();
        assert_eq!(ids, ["/b/sda3", "/b/sdb1", "/b/sdc1"]);
    }

    // ---- mounting and VolumeAdded

    fn storage(volumes: Vec<RawVolume>) -> Storage<FakeUdisks> {
        Storage::new(FakeUdisks::new(volumes))
    }

    #[test]
    fn volumes_present_at_start_are_mounted_but_not_announced_as_added() {
        let s = storage(vec![stick("/b/sdb1", "/d/sdb")]);
        let changes = s.refresh().expect("refresh");
        assert!(changes.added.is_empty());
        assert!(changes.changed);
        let v = &s.list()[0];
        assert!(v.mounted, "mounted at start");
        assert!(v.free_bytes > 0);
    }

    #[test]
    fn a_hot_plugged_volume_is_added_once_and_announced_already_mounted() {
        let s = storage(vec![]);
        s.refresh().expect("first");
        s.udisks.plug(stick("/b/sdb1", "/d/sdb"));
        let changes = s.refresh().expect("second");
        assert_eq!(changes.added, ["/b/sdb1"]);
        assert!(changes.changed);
        assert!(s.list()[0].mounted, "the list already shows it mounted");
        let again = s.refresh().expect("third");
        assert!(!again.any(), "nothing new: {again:?}");
    }

    #[test]
    fn removable_volumes_are_mounted_nosuid_nodev_noexec() {
        let s = storage(vec![stick("/b/sdb1", "/d/sdb")]);
        s.refresh().expect("refresh");
        assert_eq!(
            s.udisks.calls(),
            ["mount:/b/sdb1:nosuid,nodev,noexec".to_owned()]
        );
    }

    #[test]
    fn unknown_filesystems_internal_disks_and_mounted_volumes_are_never_mounted() {
        let mut already = stick("/b/sdd1", "/d/sdd");
        already.mount_points = vec!["/run/media/x/A".to_owned()];
        let s = storage(vec![
            raw("/b/sdb1", "/d/sdb", "f2fs"),
            internal("/b/sda3", "ext4", ""),
            already,
        ]);
        s.refresh().expect("refresh");
        assert_eq!(s.udisks.calls(), Vec::<String>::new());
    }

    #[test]
    fn a_hot_plugged_unsupported_volume_is_announced_but_not_mounted() {
        let s = storage(vec![]);
        s.refresh().expect("first");
        s.udisks.plug(raw("/b/sdb1", "/d/sdb", "f2fs"));
        let changes = s.refresh().expect("second");
        assert_eq!(changes.added, ["/b/sdb1"]);
        assert_eq!(s.udisks.calls(), Vec::<String>::new());
        assert!(!s.list()[0].mounted);
    }

    #[test]
    fn a_failed_mount_is_not_retried_on_every_refresh() {
        let s = storage(vec![]);
        s.refresh().expect("first");
        s.udisks.refuse_mount("/b/sdb1");
        s.udisks.plug(stick("/b/sdb1", "/d/sdb"));
        s.refresh().expect("second");
        s.refresh().expect("third");
        assert_eq!(s.udisks.calls().len(), 1);
        assert!(!s.list()[0].mounted);
    }

    #[test]
    fn a_volume_that_leaves_and_comes_back_is_a_new_hot_plug() {
        let s = storage(vec![]);
        s.refresh().expect("first");
        s.udisks.plug(stick("/b/sdb1", "/d/sdb"));
        s.refresh().expect("plugged");
        s.udisks.set(vec![]);
        let gone = s.refresh().expect("unplugged");
        assert!(gone.changed && gone.added.is_empty());
        s.udisks.plug(stick("/b/sdb1", "/d/sdb"));
        let back = s.refresh().expect("plugged again");
        assert_eq!(back.added, ["/b/sdb1"]);
        assert_eq!(s.udisks.calls().len(), 2, "mounted again");
    }

    #[test]
    fn an_internal_disk_appearing_later_is_not_announced() {
        let s = storage(vec![]);
        s.refresh().expect("first");
        s.udisks.plug(internal("/b/sda3", "ext4", "/mnt/games"));
        let changes = s.refresh().expect("second");
        assert!(changes.added.is_empty());
        assert!(changes.changed);
    }

    #[test]
    fn listing_is_not_blocked_while_a_mount_runs() {
        use std::sync::{mpsc, Arc, Weak};
        use std::time::Duration;

        /// A udisks whose mount asks the storage for its list from another thread.
        struct Probe {
            fake: FakeUdisks,
            storage: Mutex<Weak<Storage<Probe>>>,
            answered: Mutex<Option<bool>>,
        }
        impl Udisks for Probe {
            fn volumes(&self) -> Result<Vec<RawVolume>, String> {
                self.fake.volumes()
            }
            fn mount(&self, id: &str, options: &str) -> Result<(), String> {
                let storage = self.storage.lock().expect("lock").upgrade().expect("alive");
                let (tx, rx) = mpsc::channel();
                std::thread::spawn(move || {
                    let _ = storage.list();
                    let _ = tx.send(());
                });
                let ok = rx.recv_timeout(Duration::from_secs(2)).is_ok();
                *self.answered.lock().expect("lock") = Some(ok);
                self.fake.mount(id, options)
            }
            fn unmount(&self, id: &str) -> Result<(), UnmountError> {
                self.fake.unmount(id)
            }
            fn power_off(&self, id: &str) -> Result<(), String> {
                self.fake.power_off(id)
            }
        }

        let storage = Arc::new(Storage::new(Probe {
            fake: FakeUdisks::new(vec![stick("/b/sdb1", "/d/sdb")]),
            storage: Mutex::new(Weak::new()),
            answered: Mutex::new(None),
        }));
        *storage.udisks.storage.lock().expect("lock") = Arc::downgrade(&storage);
        storage.refresh().expect("refresh");
        assert_eq!(
            *storage.udisks.answered.lock().expect("lock"),
            Some(true),
            "list() waited for the mount"
        );
    }

    // ---- eject

    #[test]
    fn eject_unmounts_powers_off_and_the_volume_leaves() {
        let s = storage(vec![stick("/b/sdb1", "/d/sdb")]);
        s.refresh().expect("start");
        assert_eq!(s.eject("/b/sdb1"), Status::Ok);
        assert_eq!(
            s.udisks.calls()[1..],
            ["unmount:/b/sdb1".to_owned(), "power-off:/b/sdb1".to_owned()]
        );
        let changes = s.refresh().expect("after");
        assert!(changes.changed);
        assert!(s.list().is_empty());
    }

    #[test]
    fn a_busy_volume_stays_mounted_and_listed() {
        let s = storage(vec![stick("/b/sdb1", "/d/sdb")]);
        s.refresh().expect("start");
        s.udisks.set_busy("/b/sdb1", true);
        assert_eq!(s.eject("/b/sdb1"), Status::Busy);
        assert!(!s.udisks.calls().iter().any(|c| c.starts_with("power-off")));
        s.refresh().expect("after");
        assert!(s.list()[0].mounted);
    }

    #[test]
    fn a_busy_second_partition_brings_the_first_back() {
        let s = storage(vec![stick("/b/sdb1", "/d/sdb"), stick("/b/sdb2", "/d/sdb")]);
        s.refresh().expect("start");
        s.udisks.set_busy("/b/sdb2", true);
        assert_eq!(s.eject("/b/sdb1"), Status::Busy);
        s.refresh().expect("after");
        assert!(s.list().iter().all(|v| v.mounted), "{:?}", s.list());
        assert!(!s.udisks.calls().iter().any(|c| c.starts_with("power-off")));
    }

    #[test]
    fn eject_takes_every_partition_of_the_drive_off_together() {
        let s = storage(vec![stick("/b/sdb1", "/d/sdb"), stick("/b/sdb2", "/d/sdb")]);
        s.refresh().expect("start");
        assert_eq!(s.eject("/b/sdb2"), Status::Ok);
        let calls = s.udisks.calls();
        assert_eq!(calls.iter().filter(|c| c.starts_with("unmount")).count(), 2);
        assert_eq!(
            calls.iter().filter(|c| c.starts_with("power-off")).count(),
            1
        );
    }

    #[test]
    fn an_ejected_volume_is_not_mounted_again_by_the_next_refresh() {
        // The drive is still there between the unmount and the power-off completing; udisks
        // signals that arrive then must not mount it again.
        let s = storage(vec![stick("/b/sdb1", "/d/sdb")]);
        s.refresh().expect("start");
        let mut pulled = stick("/b/sdb1", "/d/sdb");
        pulled.mount_points.clear();
        s.udisks.set(vec![pulled]);
        s.refresh().expect("unmounted by someone else");
        assert_eq!(
            s.udisks.calls().len(),
            1,
            "no second mount: {:?}",
            s.udisks.calls()
        );
    }

    #[test]
    fn eject_statuses_for_bad_ids_internal_and_unsupported_volumes() {
        let s = storage(vec![
            internal("/b/sda3", "ext4", "/mnt/games"),
            raw("/b/sdb1", "/d/sdb", "f2fs"),
        ]);
        s.refresh().expect("start");
        assert_eq!(s.eject(""), Status::Invalid);
        assert_eq!(s.eject("/b/nope"), Status::UnknownVolume);
        assert_eq!(s.eject("/b/sda3"), Status::Failed);
        assert_eq!(s.eject("/b/sdb1"), Status::Unsupported);
        assert!(s.udisks.calls().is_empty());
    }

    #[test]
    fn status_strings_are_the_contracts() {
        assert_eq!(Status::Ok.as_str(), "ok");
        assert_eq!(Status::UnknownVolume.as_str(), "unknown-volume");
        assert_eq!(Status::Busy.as_str(), "busy");
        assert_eq!(Status::Unsupported.as_str(), "unsupported");
        assert_eq!(Status::Invalid.as_str(), "invalid");
        assert_eq!(Status::Failed.as_str(), "failed");
    }
}
