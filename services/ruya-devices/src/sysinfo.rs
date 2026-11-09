//! org.ruyaos.Devices1.System (T-226): the collector's result, kept so that a call is cheap.
//!
//! `ruya-sysinfo` does the reading. This module only decides when: the keys that change by the second
//! ([`ruya_sysinfo::LIVE_KEYS`]) are read at every call; the others are read at the first call and
//! then at most every [`STATIC_MAX_AGE`], in the background, and a difference is announced
//! (`SystemInfoChanged`). Time is passed in, so the rule is testable; the reading itself happens on
//! the blocking pool (`dbus.rs`), never on the D-Bus executor.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use ruya_sysinfo::{collect_live, collect_static, Info, Source};

/// How old the slow-changing part may get before a call reads it again.
pub const STATIC_MAX_AGE: Duration = Duration::from_secs(30);

/// What the collector reads from: the running system, or a machine written down (`--session`).
pub type DynInfoSource = Box<dyn Source + Send + Sync>;

struct Cache {
    info: Option<Info>,
    stamp: Option<Instant>,
}

/// Which Bluetooth adapter is the primary one, and its address: asked of the Bluetooth core at
/// every read (`Bluetooth::primary_adapter`).
pub type PrimaryAdapter = Box<dyn Fn() -> Option<(String, String)> + Send + Sync>;

/// A source that adds one answer to another's: the Bluetooth adapter the service itself treats as
/// the primary one, so the System information describes the adapter the pads are paired on and not
/// whichever `hciN` sysfs lists first (T-359).
pub struct WithPrimaryAdapter {
    inner: DynInfoSource,
    primary: PrimaryAdapter,
}

impl WithPrimaryAdapter {
    pub fn new(inner: DynInfoSource, primary: PrimaryAdapter) -> Self {
        WithPrimaryAdapter { inner, primary }
    }
}

impl Source for WithPrimaryAdapter {
    fn read(&self, p: &str) -> Option<String> {
        self.inner.read(p)
    }
    fn read_bytes(&self, p: &str) -> Option<Vec<u8>> {
        self.inner.read_bytes(p)
    }
    fn list(&self, p: &str) -> Vec<String> {
        self.inner.list(p)
    }
    fn exists(&self, p: &str) -> bool {
        self.inner.exists(p)
    }
    fn resolve(&self, p: &str) -> Option<String> {
        self.inner.resolve(p)
    }
    fn modified(&self, p: &str) -> Option<u64> {
        self.inner.modified(p)
    }
    fn run(&self, p: &str, a: &[&str]) -> Option<String> {
        self.inner.run(p, a)
    }
    fn primary_bluetooth(&self) -> Option<(String, String)> {
        (self.primary)()
    }
}

pub struct SystemInfo {
    source: DynInfoSource,
    cache: Mutex<Cache>,
}

impl SystemInfo {
    pub fn new(source: DynInfoSource) -> Self {
        SystemInfo {
            source,
            cache: Mutex::new(Cache {
                info: None,
                stamp: None,
            }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Cache> {
        self.cache.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The slow part (read now when there is none yet) with the live keys read now. Blocks: call it
    /// on the blocking pool.
    pub fn current(&self, now: Instant) -> Info {
        let cached = self.lock().info.clone();
        let mut info = match cached {
            Some(info) => info,
            None => {
                let read = collect_static(self.source.as_ref());
                let mut cache = self.lock();
                cache.info = Some(read.clone());
                cache.stamp = Some(now);
                read
            }
        };
        info.merge(collect_live(self.source.as_ref()));
        info
    }

    /// The slow part is older than [`STATIC_MAX_AGE`] (and was read at least once).
    pub fn is_stale(&self, now: Instant) -> bool {
        match self.lock().stamp {
            Some(stamp) => now.saturating_duration_since(stamp) >= STATIC_MAX_AGE,
            None => false,
        }
    }

    /// Reads the slow part again if it is stale. `None`: it was not stale (or someone else is
    /// already reading it); `Some(changed)`: it was read, and `changed` says whether it differs.
    /// Blocks: call it on the blocking pool.
    pub fn refresh_if_stale(&self, now: Instant) -> Option<bool> {
        {
            let mut cache = self.lock();
            let stale = cache
                .stamp
                .is_some_and(|s| now.saturating_duration_since(s) >= STATIC_MAX_AGE);
            if !stale {
                return None;
            }
            // Claimed: a call that comes in meanwhile finds it fresh and does not start a second read.
            cache.stamp = Some(now);
        }
        let read = collect_static(self.source.as_ref());
        let mut cache = self.lock();
        let changed = cache.info.as_ref() != Some(&read);
        cache.info = Some(read);
        Some(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ruya_sysinfo::FakeSource;
    use std::sync::{Arc, Mutex as StdMutex};

    /// A source whose files can be changed while the cache holds the first reading.
    struct Shared(Arc<StdMutex<FakeSource>>);

    impl Source for Shared {
        fn read(&self, p: &str) -> Option<String> {
            self.0.lock().unwrap().read(p)
        }
        fn read_bytes(&self, p: &str) -> Option<Vec<u8>> {
            self.0.lock().unwrap().read_bytes(p)
        }
        fn list(&self, p: &str) -> Vec<String> {
            self.0.lock().unwrap().list(p)
        }
        fn exists(&self, p: &str) -> bool {
            self.0.lock().unwrap().exists(p)
        }
        fn resolve(&self, p: &str) -> Option<String> {
            self.0.lock().unwrap().resolve(p)
        }
        fn modified(&self, p: &str) -> Option<u64> {
            self.0.lock().unwrap().modified(p)
        }
        fn run(&self, p: &str, a: &[&str]) -> Option<String> {
            self.0.lock().unwrap().run(p, a)
        }
    }

    fn machine(memory_available: u64, model: &str) -> FakeSource {
        FakeSource::new()
            .file(
                "/proc/meminfo",
                &format!("MemTotal: 1000 kB\nMemAvailable: {memory_available} kB\n"),
            )
            .file(
                "/proc/cpuinfo",
                &format!("processor : 0\nmodel name : {model}\n"),
            )
    }

    fn rig(first: FakeSource) -> (SystemInfo, Arc<StdMutex<FakeSource>>) {
        let files = Arc::new(StdMutex::new(first));
        (SystemInfo::new(Box::new(Shared(files.clone()))), files)
    }

    /// Two dongles in sysfs, `hci0` first; the service's primary adapter is the second.
    fn two_dongles() -> FakeSource {
        let dev0 = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-3";
        let dev1 = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-10";
        FakeSource::new()
            .link(
                "/sys/class/bluetooth/hci0",
                &format!("{dev0}/1-3:1.0/bluetooth/hci0"),
            )
            .file(
                &format!("{dev0}/idVendor"),
                "0a12
",
            )
            .file(
                &format!("{dev0}/idProduct"),
                "0001
",
            )
            .file(
                &format!("{dev0}/product"),
                "CSR8510 A10
",
            )
            .dir(&format!("{dev0}/1-3:1.0/bluetooth/hci0"))
            .link(
                "/sys/class/bluetooth/hci1",
                &format!("{dev1}/1-10:1.0/bluetooth/hci1"),
            )
            .file(
                &format!("{dev1}/idVendor"),
                "8087
",
            )
            .file(
                &format!("{dev1}/idProduct"),
                "0a2b
",
            )
            .file(
                &format!("{dev1}/product"),
                "Intel Wireless
",
            )
            .dir(&format!("{dev1}/1-10:1.0/bluetooth/hci1"))
            .command(
                "bluetoothctl show",
                "Controller 00:11:22:33:44:00 (public)
",
            )
    }

    #[test]
    fn sysinfo_reports_the_primary_adapter() {
        use crate::bluetooth::{Bluetooth, FakeBluez};
        // The Dell's two adapters: `hci1` holds the paired pads, so it is the primary one.
        let bt = Arc::new(Bluetooth::new(FakeBluez::with_two_adapters()));
        bt.refresh().expect("fake reads");
        let ask = bt.clone();
        let source = WithPrimaryAdapter::new(
            Box::new(two_dongles()),
            Box::new(move || ask.primary_adapter()),
        );
        let info = SystemInfo::new(Box::new(source)).current(Instant::now());
        assert_eq!(info.get_text("bluetooth.usb_id"), Some("8087:0a2b"));
        assert_eq!(info.get_text("bluetooth.chipset"), Some("Intel Wireless"));
        assert_eq!(
            info.get_text("bluetooth.address"),
            Some("00:11:22:33:44:01"),
            "the primary adapter's own address, not bluetoothctl's default controller"
        );
        // An adapter the service names that sysfs does not list: the first one is described, and the
        // address is `bluetoothctl show`'s, not the other adapter's.
        let source = WithPrimaryAdapter::new(
            Box::new(two_dongles()),
            Box::new(|| Some(("hci7".to_owned(), "00:11:22:33:44:99".to_owned()))),
        );
        let info = SystemInfo::new(Box::new(source)).current(Instant::now());
        assert_eq!(info.get_text("bluetooth.usb_id"), Some("0a12:0001"));
        assert_eq!(
            info.get_text("bluetooth.address"),
            Some("00:11:22:33:44:00")
        );
        // Without the service's answer the first adapter in sysfs is taken, as before.
        let info = SystemInfo::new(Box::new(two_dongles())).current(Instant::now());
        assert_eq!(info.get_text("bluetooth.usb_id"), Some("0a12:0001"));
    }

    #[test]
    fn live_values_are_read_at_every_call_the_rest_is_kept() {
        let (info, files) = rig(machine(400, "Old CPU"));
        let t0 = Instant::now();
        let first = info.current(t0);
        assert_eq!(first.get_unsigned("memory.used_bytes"), Some(600 * 1024));
        assert_eq!(first.get_text("cpu.model"), Some("Old CPU"));
        *files.lock().unwrap() = machine(100, "New CPU");
        let second = info.current(t0 + Duration::from_secs(2));
        assert_eq!(
            second.get_unsigned("memory.used_bytes"),
            Some(900 * 1024),
            "live: read again"
        );
        assert_eq!(
            second.get_text("cpu.model"),
            Some("Old CPU"),
            "slow: from the cache"
        );
    }

    #[test]
    fn the_slow_part_is_read_again_after_thirty_seconds_and_a_change_is_reported() {
        let (info, files) = rig(machine(400, "Old CPU"));
        let t0 = Instant::now();
        info.current(t0);
        assert!(!info.is_stale(t0 + Duration::from_secs(29)));
        assert_eq!(info.refresh_if_stale(t0 + Duration::from_secs(29)), None);
        *files.lock().unwrap() = machine(400, "New CPU");
        let late = t0 + Duration::from_secs(31);
        assert!(info.is_stale(late));
        assert_eq!(info.refresh_if_stale(late), Some(true));
        assert_eq!(info.current(late).get_text("cpu.model"), Some("New CPU"));
        // Nothing changed this time: read, but not announced.
        let later = late + Duration::from_secs(31);
        assert_eq!(info.refresh_if_stale(later), Some(false));
    }

    #[test]
    fn a_read_in_progress_is_not_started_twice() {
        let (info, _) = rig(machine(400, "CPU"));
        let t0 = Instant::now();
        info.current(t0);
        let late = t0 + Duration::from_secs(40);
        assert_eq!(info.refresh_if_stale(late), Some(false));
        assert_eq!(
            info.refresh_if_stale(late),
            None,
            "stamped by the first: not stale for the second"
        );
    }

    #[test]
    fn nothing_is_stale_before_the_first_read() {
        let (info, _) = rig(machine(400, "CPU"));
        assert!(!info.is_stale(Instant::now() + Duration::from_secs(1000)));
        assert_eq!(info.refresh_if_stale(Instant::now()), None);
    }
}
