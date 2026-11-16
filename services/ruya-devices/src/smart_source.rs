//! Where the SMART records of `storage.drives` come from (RUY-737): udisks2's drives, read when the
//! System information collects its slow part and kept until udisks2 says a SMART value changed
//! (`invalidate`). No timer of its own: udisks2 refreshes ATA SMART itself (about every 10 minutes)
//! and tells us with `PropertiesChanged` (`dbus::watch_smart`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use ruya_sysinfo::{DriveSmart, Source};

use crate::smart::{assess, AtaProps, Raw};

/// Reads every drive udisks2 knows, by block device name (`sda`, `nvme0n1`). An `Err` is "udisks2 is
/// not there": every drive's SMART stays unknown.
pub type SmartReader = Box<dyn Fn() -> Result<HashMap<String, Raw>, String> + Send + Sync>;

pub struct SmartCache {
    reader: SmartReader,
    drives: Mutex<Option<HashMap<String, Raw>>>,
}

impl SmartCache {
    pub fn new(reader: SmartReader) -> Self {
        SmartCache {
            reader,
            drives: Mutex::new(None),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<HashMap<String, Raw>>> {
        self.drives.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The record of one block device; reads udisks2 first if nothing is kept. Blocks.
    pub fn lookup(&self, block: &str) -> Option<DriveSmart> {
        if self.lock().is_none() {
            // A failed read is not kept: the next collection asks again.
            let read = (self.reader)().ok()?;
            *self.lock() = Some(read);
        }
        let kept = self.lock();
        assess(kept.as_ref()?.get(block)?)
    }

    /// udisks2 reported a change: read again at the next lookup.
    pub fn invalidate(&self) {
        *self.lock() = None;
    }
}

/// A source with the SMART records of udisks2 added.
pub struct WithSmart {
    inner: Box<dyn Source + Send + Sync>,
    cache: Arc<SmartCache>,
}

impl WithSmart {
    pub fn new(inner: Box<dyn Source + Send + Sync>, cache: Arc<SmartCache>) -> Self {
        WithSmart { inner, cache }
    }
}

impl Source for WithSmart {
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
        self.inner.primary_bluetooth()
    }
    fn drive_smart(&self, block: &str) -> Option<DriveSmart> {
        self.cache.lookup(block)
    }
}

/// `--session`: the sample machine's `sda`, as `RUYA_DEVICES_FAKE_SMART` says: `ok` (default),
/// `warning`, `failing`, `unsupported`, or `none` (udisks2 not there).
pub fn session_reader(kind: Option<String>) -> SmartReader {
    Box::new(move || {
        let ata = |tweak: &dyn Fn(&mut AtaProps)| {
            let mut p = AtaProps {
                supported: true,
                enabled: true,
                updated: 1_700_000_000,
                selftest: "success".to_owned(),
                temperature_k: 311.15,
                power_on_seconds: 12_345 * 3600,
                ..AtaProps::default()
            };
            tweak(&mut p);
            Raw::Ata(p)
        };
        let raw = match kind.as_deref() {
            Some("none") => return Err("absent".to_owned()),
            Some("unsupported") => Raw::Neither,
            Some("warning") => ata(&|p| p.bad_sectors = 8),
            Some("failing") => ata(&|p| p.failing = true),
            _ => ata(&|_| {}),
        };
        Ok(HashMap::from([("sda".to_owned(), raw)]))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn counting(reads: Arc<AtomicUsize>, bad_sectors: Arc<AtomicUsize>) -> SmartCache {
        SmartCache::new(Box::new(move || {
            reads.fetch_add(1, Ordering::SeqCst);
            let p = AtaProps {
                supported: true,
                enabled: true,
                updated: 1,
                bad_sectors: bad_sectors.load(Ordering::SeqCst) as i64,
                ..AtaProps::default()
            };
            Ok(HashMap::from([("sda".to_owned(), Raw::Ata(p))]))
        }))
    }

    #[test]
    fn udisks_is_read_once_until_it_reports_a_change() {
        let reads = Arc::new(AtomicUsize::new(0));
        let bad = Arc::new(AtomicUsize::new(0));
        let cache = counting(reads.clone(), bad.clone());
        assert_eq!(cache.lookup("sda").map(|r| r.smart), Some("ok".to_owned()));
        assert_eq!(cache.lookup("sda").map(|r| r.smart), Some("ok".to_owned()));
        assert_eq!(reads.load(Ordering::SeqCst), 1, "kept");
        bad.store(2, Ordering::SeqCst);
        assert_eq!(
            cache.lookup("sda").map(|r| r.smart),
            Some("ok".to_owned()),
            "still the kept one"
        );
        cache.invalidate();
        assert_eq!(
            cache.lookup("sda").map(|r| r.smart),
            Some("warning".to_owned())
        );
        assert_eq!(reads.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_drive_udisks_does_not_list_has_no_record() {
        let cache = counting(Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        assert_eq!(cache.lookup("sdz"), None);
    }

    #[test]
    fn udisks_absent_gives_no_record_and_is_asked_again_next_time() {
        let reads = Arc::new(AtomicUsize::new(0));
        let counter = reads.clone();
        let cache = SmartCache::new(Box::new(move || {
            counter.fetch_add(1, Ordering::SeqCst);
            Err("absent".to_owned())
        }));
        assert_eq!(cache.lookup("sda"), None);
        assert_eq!(cache.lookup("sda"), None);
        assert_eq!(reads.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn the_session_fixture_has_each_state() {
        for (kind, want) in [
            (None, Some("ok")),
            (Some("warning"), Some("warning")),
            (Some("failing"), Some("failing")),
            (Some("unsupported"), Some("unsupported")),
            (Some("none"), None),
        ] {
            let cache = SmartCache::new(session_reader(kind.map(str::to_owned)));
            assert_eq!(
                cache.lookup("sda").map(|r| r.smart).as_deref(),
                want,
                "{kind:?}"
            );
        }
    }

    #[test]
    fn the_wrapper_answers_drive_smart_and_forwards_the_rest() {
        let cache = Arc::new(counting(
            Arc::new(AtomicUsize::new(0)),
            Arc::new(AtomicUsize::new(0)),
        ));
        let inner = ruya_sysinfo::FakeSource::new().file("/x", "1");
        let src = WithSmart::new(Box::new(inner), cache);
        assert_eq!(src.read("/x").as_deref(), Some("1"));
        assert_eq!(
            src.drive_smart("sda").map(|r| r.smart),
            Some("ok".to_owned())
        );
    }
}
