//! udisks2 over its D-Bus API (system bus, `org.freedesktop.UDisks2`), with zbus. Linux only.
//! udisks2 not being there (not installed, not startable) reads as "no volumes", never as an
//! error. The rules are in `storage.rs`.
//!
//! The service runs as `ruya-shell`; polkit lets that user do what is listed in
//! `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-storage.rules`, and nothing more.

use std::collections::HashMap;
use std::ffi::CString;

use futures_lite::future;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, DBusError};

use crate::smart::{AtaProps, NvmeProps, Raw};
use crate::storage::{RawVolume, Udisks, UnmountError};

pub const UDISKS: &str = "org.freedesktop.UDisks2";
const ROOT: &str = "/org/freedesktop/UDisks2";
const BLOCK: &str = "org.freedesktop.UDisks2.Block";
const FILESYSTEM: &str = "org.freedesktop.UDisks2.Filesystem";
const DRIVE: &str = "org.freedesktop.UDisks2.Drive";
const OBJECTS: &str = "org.freedesktop.DBus.ObjectManager";

type Dict = HashMap<String, OwnedValue>;
type Objects = HashMap<OwnedObjectPath, HashMap<String, Dict>>;

pub struct UdisksClient {
    conn: Connection,
}

fn flag(d: &Dict, key: &str) -> bool {
    matches!(d.get(key).map(|v| &**v), Some(Value::Bool(true)))
}

fn text(d: &Dict, key: &str) -> String {
    match d.get(key).map(|v| &**v) {
        Some(Value::Str(s)) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn size(d: &Dict, key: &str) -> u64 {
    match d.get(key).map(|v| &**v) {
        Some(Value::U64(n)) => *n,
        _ => 0,
    }
}

fn object(d: &Dict, key: &str) -> String {
    match d.get(key).map(|v| &**v) {
        // "/" is udisks' "no drive".
        Some(Value::ObjectPath(p)) if p.as_str() != "/" => p.as_str().to_owned(),
        _ => String::new(),
    }
}

/// `MountPoints` is an array of NUL-terminated byte strings.
fn mount_points(d: &Dict) -> Vec<String> {
    let Some(Value::Array(points)) = d.get("MountPoints").map(|v| &**v) else {
        return Vec::new();
    };
    points
        .iter()
        .filter_map(|p| {
            let Value::Array(bytes) = p else { return None };
            let raw: Vec<u8> = bytes
                .iter()
                .filter_map(|b| match b {
                    Value::U8(b) if *b != 0 => Some(*b),
                    _ => None,
                })
                .collect();
            (!raw.is_empty()).then(|| String::from_utf8_lossy(&raw).into_owned())
        })
        .collect()
}

/// Free bytes of the filesystem mounted at `path`, 0 when it cannot be read.
fn free_bytes(path: &str) -> u64 {
    let Ok(c_path) = CString::new(path) else {
        return 0;
    };
    // SAFETY: `st` is plain data that statvfs fills in; both pointers are valid for the call.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), &mut st) };
    if rc != 0 {
        return 0;
    }
    #[allow(clippy::unnecessary_cast)]
    let (blocks, unit) = (st.f_bavail as u64, st.f_frsize as u64);
    blocks.saturating_mul(unit)
}

/// The error name of a failed call; anything that is not a D-Bus error reply is a plain failure.
fn name_of(err: &zbus::Error) -> String {
    match err {
        zbus::Error::MethodError(name, _, _) => name.as_str().to_owned(),
        zbus::Error::FDO(e) => e.name().as_str().to_owned(),
        other => format!("org.ruyaos.Error.Io: {other}"),
    }
}

/// Whether a bus error only says "udisks2 is not there" (not installed, cannot be started, gone
/// while we asked).
fn is_absent(name: &str) -> bool {
    matches!(
        name,
        "org.freedesktop.DBus.Error.ServiceUnknown"
            | "org.freedesktop.DBus.Error.NameHasNoOwner"
            | "org.freedesktop.DBus.Error.Spawn.ServiceNotFound"
            | "org.freedesktop.DBus.Error.Spawn.ChildExited"
            | "org.freedesktop.DBus.Error.Spawn.Failed"
            | "org.freedesktop.DBus.Error.Spawn.ExecFailed"
            | "org.freedesktop.DBus.Error.UnknownObject"
    )
}

impl UdisksClient {
    pub fn connect() -> Result<Self, String> {
        future::block_on(Connection::system())
            .map(|conn| UdisksClient { conn })
            .map_err(|e| e.to_string())
    }

    async fn call(
        &self,
        path: &str,
        iface: &str,
        member: &str,
        body: &(impl serde::Serialize + zbus::zvariant::DynamicType),
    ) -> Result<zbus::Message, String> {
        self.conn
            .call_method(Some(UDISKS), path, Some(iface), member, body)
            .await
            .map_err(|e| name_of(&e))
    }

    async fn objects(&self) -> Result<Objects, String> {
        let reply = self.call(ROOT, OBJECTS, "GetManagedObjects", &()).await?;
        reply
            .body()
            .deserialize()
            .map_err(|e| format!("org.ruyaos.Error.Io: {e}"))
    }

    async fn read(&self) -> Result<Vec<RawVolume>, String> {
        let objects = match self.objects().await {
            Ok(o) => o,
            Err(name) if is_absent(&name) => return Ok(Vec::new()),
            Err(name) => return Err(name),
        };
        let mut out = Vec::new();
        for (path, ifaces) in &objects {
            let (Some(block), Some(fs)) = (ifaces.get(BLOCK), ifaces.get(FILESYSTEM)) else {
                continue;
            };
            let drive_path = object(block, "Drive");
            let drive = objects
                .iter()
                .find(|(p, _)| p.as_str() == drive_path)
                .and_then(|(_, i)| i.get(DRIVE));
            let model = drive.map_or_else(String::new, |d| {
                format!("{} {}", text(d, "Vendor"), text(d, "Model"))
            });
            let mount_points = mount_points(fs);
            let free = mount_points.first().map_or(0, |p| free_bytes(p));
            out.push(RawVolume {
                id: path.as_str().to_owned(),
                drive: drive_path,
                label: text(block, "IdLabel"),
                model,
                id_type: text(block, "IdType"),
                size_bytes: size(block, "Size"),
                free_bytes: free,
                hint_system: flag(block, "HintSystem"),
                hint_ignore: flag(block, "HintIgnore"),
                drive_removable: drive.is_some_and(|d| flag(d, "Removable")),
                bus: drive.map_or_else(String::new, |d| text(d, "ConnectionBus")),
                mount_points,
                read_only: flag(block, "ReadOnly"),
            });
        }
        Ok(out)
    }

    /// The drive object of a block device, with whether it can be powered off or ejected.
    async fn drive_of(&self, id: &str) -> Result<(String, bool, bool), String> {
        let objects = self.objects().await?;
        let block = objects
            .iter()
            .find(|(p, _)| p.as_str() == id)
            .and_then(|(_, i)| i.get(BLOCK))
            .ok_or_else(|| "org.ruyaos.Error.UnknownVolume".to_owned())?;
        let drive_path = object(block, "Drive");
        let drive = objects
            .iter()
            .find(|(p, _)| p.as_str() == drive_path)
            .and_then(|(_, i)| i.get(DRIVE))
            .ok_or_else(|| "org.ruyaos.Error.NoDrive".to_owned())?;
        Ok((
            drive_path,
            flag(drive, "CanPowerOff"),
            flag(drive, "Ejectable"),
        ))
    }
}

impl Udisks for UdisksClient {
    fn volumes(&self) -> Result<Vec<RawVolume>, String> {
        future::block_on(self.read())
    }

    fn mount(&self, id: &str, options: &str) -> Result<(), String> {
        let mut args: HashMap<&str, Value<'_>> = HashMap::new();
        args.insert("options", Value::from(options));
        match future::block_on(self.call(id, FILESYSTEM, "Mount", &(args,))) {
            Ok(_) => Ok(()),
            Err(name) if name == "org.freedesktop.UDisks2.Error.AlreadyMounted" => Ok(()),
            Err(name) => Err(name),
        }
    }

    fn unmount(&self, id: &str) -> Result<(), UnmountError> {
        let args: HashMap<&str, Value<'_>> = HashMap::new();
        match future::block_on(self.call(id, FILESYSTEM, "Unmount", &(args,))) {
            Ok(_) => Ok(()),
            Err(name) if name == "org.freedesktop.UDisks2.Error.NotMounted" => Ok(()),
            Err(name) if name == "org.freedesktop.UDisks2.Error.DeviceBusy" => {
                Err(UnmountError::Busy)
            }
            Err(name) => Err(UnmountError::Failed(name)),
        }
    }

    fn power_off(&self, id: &str) -> Result<(), String> {
        future::block_on(async {
            let (drive, can_power_off, ejectable) = self.drive_of(id).await?;
            let member = if can_power_off {
                "PowerOff"
            } else if ejectable {
                "Eject"
            } else {
                // Nothing to switch off (an SD card in a reader): unmounted is safe to remove.
                return Ok(());
            };
            let args: HashMap<&str, Value<'_>> = HashMap::new();
            self.call(&drive, DRIVE, member, &(args,)).await.map(|_| ())
        })
    }
}

// --- SMART (RUY-737) -------------------------------------------------------------------------------

const ATA: &str = "org.freedesktop.UDisks2.Drive.Ata";
const NVME: &str = "org.freedesktop.UDisks2.NVMe.Controller";
const PARTITION: &str = "org.freedesktop.UDisks2.Partition";

/// A number of whatever width udisks2 used for it.
fn number(d: &Dict, key: &str) -> Option<f64> {
    match d.get(key).map(|v| &**v)? {
        Value::U8(n) => Some(f64::from(*n)),
        Value::I16(n) => Some(f64::from(*n)),
        Value::U16(n) => Some(f64::from(*n)),
        Value::I32(n) => Some(f64::from(*n)),
        Value::U32(n) => Some(f64::from(*n)),
        Value::I64(n) => Some(*n as f64),
        Value::U64(n) => Some(*n as f64),
        Value::F64(n) => Some(*n),
        _ => None,
    }
}

fn whole(d: &Dict, key: &str) -> u64 {
    number(d, key).filter(|n| *n > 0.0).map_or(0, |n| n as u64)
}

fn words(d: &Dict, key: &str) -> Vec<String> {
    match d.get(key).map(|v| &**v) {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|i| match i {
                Value::Str(s) => Some(s.as_str().to_owned()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// `sda` from the block's NUL-terminated `Device` bytes (`/dev/sda`).
fn block_name(block: &Dict) -> Option<String> {
    let Some(Value::Array(bytes)) = block.get("Device").map(|v| &**v) else {
        return None;
    };
    let raw: Vec<u8> = bytes
        .iter()
        .filter_map(|b| match b {
            Value::U8(b) if *b != 0 => Some(*b),
            _ => None,
        })
        .collect();
    let path = String::from_utf8_lossy(&raw).into_owned();
    path.strip_prefix("/dev/").map(str::to_owned)
}

fn ata_props(d: &Dict) -> AtaProps {
    AtaProps {
        supported: flag(d, "SmartSupported"),
        enabled: flag(d, "SmartEnabled"),
        updated: whole(d, "SmartUpdated"),
        failing: flag(d, "SmartFailing"),
        bad_sectors: number(d, "SmartNumBadSectors").map_or(0, |n| n as i64),
        selftest: text(d, "SmartSelftestStatus"),
        temperature_k: number(d, "SmartTemperature").unwrap_or(0.0),
        power_on_seconds: whole(d, "SmartPowerOnSeconds"),
    }
}

impl UdisksClient {
    /// The attributes only a method gives: spare, its threshold and the percentage used.
    async fn nvme_attributes(&self, drive: &str) -> Dict {
        let options: HashMap<&str, Value<'_>> = HashMap::new();
        match self
            .call(drive, NVME, "SmartGetAttributes", &(options,))
            .await
        {
            Ok(reply) => reply.body().deserialize().unwrap_or_default(),
            Err(_) => Dict::new(),
        }
    }

    async fn smart(&self) -> Result<HashMap<String, Raw>, String> {
        let objects = self.objects().await?;
        let mut out = HashMap::new();
        for ifaces in objects.values() {
            let Some(block) = ifaces.get(BLOCK) else {
                continue;
            };
            // A partition is not a drive; a block without a drive (loop, zram) has no SMART either.
            if ifaces.contains_key(PARTITION) {
                continue;
            }
            let drive_path = object(block, "Drive");
            let Some(name) = block_name(block).filter(|_| !drive_path.is_empty()) else {
                continue;
            };
            let Some(drive) = objects
                .iter()
                .find(|(p, _)| p.as_str() == drive_path)
                .map(|(_, i)| i)
            else {
                continue;
            };
            let raw = if let Some(d) = drive.get(ATA) {
                Raw::Ata(ata_props(d))
            } else if let Some(d) = drive.get(NVME) {
                let attrs = self.nvme_attributes(&drive_path).await;
                Raw::Nvme(NvmeProps {
                    updated: whole(d, "SmartUpdated"),
                    critical: words(d, "SmartCriticalWarning"),
                    power_on_hours: whole(d, "SmartPowerOnHours"),
                    temperature_k: whole(d, "SmartTemperature") as u32,
                    percent_used: number(&attrs, "percent_used").map(|n| n as u64),
                    avail_spare: number(&attrs, "avail_spare").map(|n| n as u64),
                    spare_thresh: number(&attrs, "spare_thresh").map(|n| n as u64),
                })
            } else {
                Raw::Neither
            };
            out.insert(name, raw);
        }
        Ok(out)
    }

    /// Every drive's SMART state, by block device name. Blocks.
    pub fn smart_drives(&self) -> Result<HashMap<String, Raw>, String> {
        future::block_on(self.smart())
    }
}
