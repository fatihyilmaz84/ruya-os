//! The Linux side of Ruya Input: one thread per physical pad (evdev), the navigation keyboard
//! and the virtual pads (uinput), the udev monitor, rumble requests, the watchdog, and the bus.
//! Every rule is in `routing`; this file only moves events and performs side effects.

mod sys;

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, BorrowedFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use evdev::uinput::{VirtualDevice, VirtualDeviceBuilder};
use evdev::{AbsoluteAxisType, AttributeSet, Device, EventType, FFEffectType, InputEvent, Key};

use crate::accounts::PasswdAccounts;
use crate::acl;
use crate::book::{Book, DirStore};
use crate::caps::{self, Part, Probe};
use crate::dbus::{serve, DynBackend, Shared};
use crate::identity::{self, Hardware};
use crate::mapping::{KeyEvent, NavKey};
use crate::notify::{watchdog_interval, Notifier};
use crate::pad::{code, Normalizer, OutEvent, PadLayout, Range, Rumble, OWN_PHYS_PREFIX};
use crate::routing::{Backend, Created, PadInfo, PadKey, Router, VirtualId, VirtualSpec};
use crate::udev::{database_properties, parse_monitor_message};
use sys::UinputPad;

const RESCAN_INTERVAL: Duration = Duration::from_secs(2);
const TICK: Duration = Duration::from_millis(500);
/// The tick while a button test runs: held-back axis values go out within half their interval.
const TEST_TICK: Duration = Duration::from_millis(16);
const NAV_NAME: &str = "RuyaOS Navigation";
const STATE_DIR: &str = "/var/lib/ruya-input";

fn nav_to_key(key: NavKey) -> Key {
    match key {
        NavKey::Up => Key::KEY_UP,
        NavKey::Down => Key::KEY_DOWN,
        NavKey::Left => Key::KEY_LEFT,
        NavKey::Right => Key::KEY_RIGHT,
        NavKey::Accept => Key::KEY_ENTER,
        NavKey::Back => Key::KEY_ESC,
        NavKey::Menu => Key::KEY_MENU,
        NavKey::Guide => Key::KEY_HOMEPAGE,
        NavKey::PrevTab => Key::KEY_PAGEUP,
        NavKey::NextTab => Key::KEY_PAGEDOWN,
    }
}

fn build_nav_keyboard() -> io::Result<VirtualDevice> {
    let mut keys = AttributeSet::<Key>::new();
    for nav in [
        NavKey::Up,
        NavKey::Down,
        NavKey::Left,
        NavKey::Right,
        NavKey::Accept,
        NavKey::Back,
        NavKey::Menu,
        NavKey::Guide,
        NavKey::PrevTab,
        NavKey::NextTab,
    ] {
        keys.insert(nav_to_key(nav));
    }
    // No phys: the navigation keyboard keeps uaccess, so the shell's session can read it.
    VirtualDeviceBuilder::new()?
        .name(NAV_NAME)
        .with_keys(&keys)?
        .build()
}

/// The physical pads' descriptors, for rumble (a dup of the pump thread's fd).
type Physicals = Arc<Mutex<HashMap<PadKey, File>>>;

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A rumble request from a virtual pad's reader thread to the router.
enum FfCall {
    Upload {
        id: VirtualId,
        effect: i16,
        rumble: Rumble,
        reply: mpsc::SyncSender<Result<(), i32>>,
    },
    Play {
        id: VirtualId,
        effect: i16,
        value: i32,
    },
    Erase {
        id: VirtualId,
        effect: i16,
    },
}

struct VirtualPad {
    pad: Arc<UinputPad>,
    alive: Arc<AtomicBool>,
}

pub struct LinuxBackend {
    nav: VirtualDevice,
    pads: HashMap<VirtualId, VirtualPad>,
    next: VirtualId,
    physicals: Physicals,
    ff: mpsc::Sender<FfCall>,
}

/// Reads an app's rumble requests from one virtual pad until it is destroyed.
fn ff_reader(id: VirtualId, pad: Arc<UinputPad>, alive: Arc<AtomicBool>, ff: mpsc::Sender<FfCall>) {
    while alive.load(Ordering::Relaxed) {
        for ev in pad.read(200) {
            match (ev.kind, ev.code) {
                (sys::EV_UINPUT, sys::UI_FF_UPLOAD) => {
                    let Ok(mut up) = pad.begin_upload(ev.value as u32) else {
                        continue;
                    };
                    up.retval = match up.effect.rumble() {
                        Some(rumble) => {
                            let (reply, answer) = mpsc::sync_channel(1);
                            let call = FfCall::Upload {
                                id,
                                effect: up.effect.id,
                                rumble,
                                reply,
                            };
                            let answer = ff
                                .send(call)
                                .ok()
                                .and_then(|_| answer.recv_timeout(Duration::from_secs(1)).ok());
                            match answer {
                                Some(Ok(())) => 0,
                                Some(Err(errno)) => -errno,
                                None => -libc::EIO,
                            }
                        }
                        None => -libc::EINVAL,
                    };
                    pad.end_upload(up);
                }
                (sys::EV_UINPUT, sys::UI_FF_ERASE) => {
                    let Ok(mut er) = pad.begin_erase(ev.value as u32) else {
                        continue;
                    };
                    let _ = ff.send(FfCall::Erase {
                        id,
                        effect: er.effect_id as i16,
                    });
                    er.retval = 0;
                    pad.end_erase(er);
                }
                (k, c) if k == code::EV_FF && c < sys::FF_GAIN => {
                    let _ = ff.send(FfCall::Play {
                        id,
                        effect: c as i16,
                        value: ev.value,
                    });
                }
                _ => {}
            }
        }
    }
}

impl Backend for LinuxBackend {
    fn nav_keys(&mut self, events: &[KeyEvent]) {
        if events.is_empty() {
            return;
        }
        let batch: Vec<InputEvent> = events
            .iter()
            .map(|&(key, pressed)| {
                InputEvent::new(EventType::KEY, nav_to_key(key).code(), pressed as i32)
            })
            .collect();
        if let Err(err) = self.nav.emit(&batch) {
            eprintln!("ruya-inputd: emit failed: {err}");
        }
    }

    fn create_virtual(&mut self, _pad: PadKey, spec: &VirtualSpec) -> Result<Created, String> {
        let (pad, sysname) =
            UinputPad::create(&spec.phys, spec.rumble).map_err(|e| e.to_string())?;
        self.next += 1;
        let id = self.next;
        let pad = Arc::new(pad);
        let alive = Arc::new(AtomicBool::new(true));
        if spec.rumble {
            let (pad, alive, ff) = (pad.clone(), alive.clone(), self.ff.clone());
            thread::spawn(move || ff_reader(id, pad, alive, ff));
        }
        self.pads.insert(id, VirtualPad { pad, alive });
        Ok(Created { id, sysname })
    }

    fn destroy_virtual(&mut self, id: VirtualId) {
        if let Some(v) = self.pads.remove(&id) {
            v.alive.store(false, Ordering::Relaxed);
            v.pad.destroy();
        }
    }

    fn write_virtual(&mut self, id: VirtualId, events: &[OutEvent]) {
        if let Some(v) = self.pads.get(&id) {
            if let Err(err) = v.pad.write(events) {
                eprintln!("ruya-inputd: writing to virtual pad {id} failed: {err}");
            }
        }
    }

    fn node_of(&mut self, sysname: &str) -> Option<String> {
        let dir = std::fs::read_dir(Path::new("/sys/devices/virtual/input").join(sysname)).ok()?;
        dir.filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .find(|n| n.starts_with("event"))
            .map(|n| format!("/dev/input/{n}"))
    }

    fn read_acl(&mut self, node: &str) -> Option<Vec<u8>> {
        sys::read_xattr(node, acl::XATTR_NAME)
    }

    fn write_acl(&mut self, node: &str, value: &[u8]) -> Result<(), String> {
        sys::write_xattr(node, acl::XATTR_NAME, value).map_err(|e| e.to_string())
    }

    fn ff_upload(&mut self, pad: PadKey, physical_id: i16, rumble: &Rumble) -> Result<i16, i32> {
        let physicals = lock(&self.physicals);
        let file = physicals.get(&pad).ok_or(libc::ENODEV)?;
        sys::ff_upload(file, physical_id, rumble)
    }

    fn ff_play(&mut self, pad: PadKey, physical_id: i16, value: i32) {
        if let Some(file) = lock(&self.physicals).get(&pad) {
            if let Err(err) = sys::ff_play(file, physical_id, value) {
                eprintln!("ruya-inputd: rumble on pad {pad} failed: {err}");
            }
        }
    }

    fn ff_erase(&mut self, pad: PadKey, physical_id: i16) {
        if let Some(file) = lock(&self.physicals).get(&pad) {
            sys::ff_erase(file, physical_id);
        }
    }
}

fn is_gamepad(device: &Device) -> bool {
    device
        .supported_keys()
        .is_some_and(|keys| keys.contains(Key::BTN_SOUTH))
}

/// Ours (a virtual pad, later a keyboard or mouse): never read back as a physical pad.
fn is_own(device: &Device) -> bool {
    device
        .physical_path()
        .is_some_and(|p| p.starts_with(OWN_PHYS_PREFIX))
}

fn driver_of(path: &Path) -> String {
    let Some(node) = path.file_name() else {
        return String::new();
    };
    let link = Path::new("/sys/class/input")
        .join(node)
        .join("device/device/driver");
    std::fs::read_link(link)
        .ok()
        .and_then(|l| l.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default()
}

/// The udev database properties of a device node.
fn udev_properties(path: &Path) -> HashMap<String, String> {
    let Ok(meta) = std::fs::metadata(path) else {
        return HashMap::new();
    };
    let rdev = meta.rdev();
    let (major, minor) = (libc::major(rdev), libc::minor(rdev));
    std::fs::read_to_string(format!("/run/udev/data/c{major}:{minor}"))
        .map(|t| database_properties(&t))
        .unwrap_or_default()
}

fn hardware(device: &Device, path: &Path) -> Hardware {
    let id = device.input_id();
    let props = udev_properties(path);
    let prop = |k: &str| props.get(k).cloned().unwrap_or_default();
    Hardware {
        bus: id.bus_type().0,
        vendor: id.vendor(),
        product: id.product(),
        uniq: device.unique_name().unwrap_or_default().to_owned(),
        serial: prop("ID_SERIAL_SHORT"),
        port_path: prop("ID_PATH"),
        phys: device.physical_path().unwrap_or_default().to_owned(),
        driver: driver_of(path),
    }
}

/// The pad's HID parent in sysfs (`/sys/class/input/eventN/device/device`), whose `input/` holds
/// the pad's sibling nodes and whose `power_supply/` its battery.
fn hid_parent(path: &Path) -> Option<PathBuf> {
    let node = path.file_name()?;
    std::fs::canonicalize(
        Path::new("/sys/class/input")
            .join(node)
            .join("device/device"),
    )
    .ok()
}

/// A sibling event node of the pad with the udev property `prop` (the motion sensors, the
/// touchpad; 06 §3 rule 2 gives `ruya-input` their ACL): usable when it opens.
fn sibling(parent: Option<&Path>, prop: &str) -> Part {
    let Some(inputs) = parent.and_then(|p| std::fs::read_dir(p.join("input")).ok()) else {
        return Part::Missing;
    };
    for input in inputs.flatten() {
        let Ok(children) = std::fs::read_dir(input.path()) else {
            continue;
        };
        for child in children.flatten() {
            let name = child.file_name();
            let Some(name) = name.to_str().filter(|n| n.starts_with("event")) else {
                continue;
            };
            let node = Path::new("/dev/input").join(name);
            if udev_properties(&node).get(prop).is_some_and(|v| v == "1") {
                return if File::open(&node).is_ok() {
                    Part::Usable
                } else {
                    Part::Present
                };
            }
        }
    }
    Part::Missing
}

/// The pad's power-supply entry: usable when it reports a capacity.
fn battery_part(parent: Option<&Path>) -> Part {
    let Some(entries) = parent.and_then(|p| std::fs::read_dir(p.join("power_supply")).ok()) else {
        return Part::Missing;
    };
    let mut found = Part::Missing;
    for entry in entries.flatten() {
        found = Part::Present;
        let capacity = std::fs::read_to_string(entry.path().join("capacity"));
        if capacity.is_ok_and(|c| c.trim().parse::<u8>().is_ok()) {
            return Part::Usable;
        }
    }
    found
}

/// What the kernel shows of a pad here (06 §4.3 `driver` and `available`).
fn probe(device: &Device, path: &Path) -> Probe {
    let abs = device.supported_absolute_axes();
    let has_abs = |a| abs.is_some_and(|s| s.contains(a));
    let parent = hid_parent(path);
    Probe {
        buttons: is_gamepad(device),
        sticks: has_abs(AbsoluteAxisType::ABS_X) && has_abs(AbsoluteAxisType::ABS_Y),
        analog_triggers: has_abs(AbsoluteAxisType::ABS_Z) || has_abs(AbsoluteAxisType::ABS_RZ),
        dpad: has_abs(AbsoluteAxisType::ABS_HAT0X)
            || device
                .supported_keys()
                .is_some_and(|k| k.contains(Key::BTN_DPAD_UP)),
        rumble: device
            .supported_ff()
            .is_some_and(|ff| ff.contains(FFEffectType::FF_RUMBLE)),
        motion: sibling(parent.as_deref(), "ID_INPUT_ACCELEROMETER"),
        touchpad: sibling(parent.as_deref(), "ID_INPUT_TOUCHPAD"),
        battery: battery_part(parent.as_deref()),
    }
}

fn layout(device: &Device, hw: &Hardware) -> PadLayout {
    let mut ranges = Vec::new();
    if let (Some(axes), Ok(info)) = (device.supported_absolute_axes(), device.get_abs_state()) {
        for abs in [
            AbsoluteAxisType::ABS_X,
            AbsoluteAxisType::ABS_Y,
            AbsoluteAxisType::ABS_Z,
            AbsoluteAxisType::ABS_RX,
            AbsoluteAxisType::ABS_RY,
            AbsoluteAxisType::ABS_RZ,
        ] {
            if axes.contains(abs) {
                let i = &info[abs.0 as usize];
                ranges.push((
                    abs.0,
                    Range {
                        min: i.minimum,
                        max: i.maximum,
                    },
                ));
            }
        }
    }
    PadLayout {
        xbox_xy: hw.driver == "xpad" || hw.vendor == 0x045e,
        ranges,
    }
}

/// Takes a pad out of the router (and its path out of the served set) however its thread ends:
/// a read error, the node gone, or a panic unwinding the thread.
struct Serving {
    shared: Arc<Shared>,
    physicals: Physicals,
    active: Arc<Mutex<HashSet<PathBuf>>>,
    path: PathBuf,
    key: PadKey,
    name: String,
    gone: String,
}

impl Drop for Serving {
    fn drop(&mut self) {
        lock(&self.physicals).remove(&self.key);
        let held = self.shared.with(|r| r.remove_pad(self.key));
        // What the pad held; a key another pad still holds stays down on the keyboard.
        let released = if held.is_empty() {
            "nothing".to_owned()
        } else {
            held.iter()
                .map(|key| format!("{key:?}"))
                .collect::<Vec<_>>()
                .join(", ")
        };
        eprintln!(
            "ruya-inputd: {} gone: {}; released {released}",
            self.name, self.gone
        );
        lock(&self.active).remove(&self.path);
    }
}

/// Reads one gamepad until it disappears (unplug -> read error).
fn pump(mut device: Device, mut normalizer: Normalizer, mut serving: Serving) {
    loop {
        let events = match device.fetch_events() {
            Ok(events) => events,
            Err(err) => {
                serving.gone = err.to_string();
                return;
            }
        };
        // One router call per SYN_REPORT frame: a read can hold several, and a release and a press
        // of one button in one call would cancel out on the virtual pad (RUY-493).
        let frames = normalizer.frames(
            events
                .into_iter()
                .map(|ev| (ev.event_type().0, ev.code(), ev.value())),
        );
        for frame in frames {
            serving.shared.with(|r| {
                if !frame.inputs.is_empty() {
                    r.input(serving.key, &frame.inputs);
                }
                r.test_input(serving.key, &frame.tests, Instant::now());
            });
        }
    }
}

fn event_nodes() -> Vec<PathBuf> {
    let Ok(dir) = std::fs::read_dir("/dev/input") else {
        return Vec::new();
    };
    dir.filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("event"))
        })
        .collect()
}

struct Scanner {
    shared: Arc<Shared>,
    physicals: Physicals,
    salt: Vec<u8>,
    /// Paths served by a pump thread; a thread removes its path when it exits.
    active: Arc<Mutex<HashSet<PathBuf>>>,
    /// Paths checked and found not to be physical gamepads.
    ignored: HashSet<PathBuf>,
}

impl Scanner {
    fn scan(&mut self) {
        let nodes = event_nodes();
        self.ignored.retain(|p| nodes.contains(p));
        for path in nodes {
            if self.ignored.contains(&path) || lock(&self.active).contains(&path) {
                continue;
            }
            match Device::open(&path) {
                Ok(device) if is_gamepad(&device) && !is_own(&device) => self.serve(device, path),
                Ok(_) => {
                    self.ignored.insert(path);
                }
                // Not (yet) ours to open (the udev rule's ACL comes with the add event) or a
                // node that vanished mid-scan: retry at the next scan.
                Err(_) => {}
            }
        }
    }

    fn serve(&mut self, device: Device, path: PathBuf) {
        let hw = hardware(&device, &path);
        let name = device.name().unwrap_or("unknown").to_owned();
        let probed = probe(&device, &path);
        let info = PadInfo {
            capabilities: caps::describe(caps::model(hw.vendor, hw.product), &probed),
            id: identity::stable_id(&hw, &self.salt),
            name: name.clone(),
            family: identity::family(&hw).to_owned(),
            connection: identity::connection(&hw).to_owned(),
            model: identity::model(&hw, &name).to_owned(),
            layout: identity::layout(&hw).to_owned(),
            rumble: device
                .supported_ff()
                .is_some_and(|ff| ff.contains(FFEffectType::FF_RUMBLE)),
        };
        let normalizer = Normalizer::new(layout(&device, &hw));
        // SAFETY: the descriptor belongs to `device`, which outlives this borrow.
        let fd = unsafe { BorrowedFd::borrow_raw(device.as_raw_fd()) };
        let dup = fd
            .try_clone_to_owned()
            .map(File::from)
            .map_err(|e| eprintln!("ruya-inputd: no rumble for {name}: {e}"))
            .ok();
        eprintln!(
            "ruya-inputd: using {name} ({}, {}, {})",
            path.display(),
            info.id,
            info.family
        );
        lock(&self.active).insert(path.clone());
        let physicals = self.physicals.clone();
        let key = self.shared.with(|r| {
            let key = r.add_pad(info, Instant::now());
            if let Some(file) = dup {
                lock(&physicals).insert(key, file);
            }
            key
        });
        let serving = Serving {
            shared: self.shared.clone(),
            physicals,
            active: self.active.clone(),
            path,
            key,
            name,
            gone: "thread ended".to_owned(),
        };
        thread::spawn(move || pump(device, normalizer, serving));
    }
}

/// The unit's StateDirectory (`/var/lib/ruya-input`, 0700, owned by ruya-input).
fn state_dir() -> PathBuf {
    std::env::var_os("STATE_DIRECTORY")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(STATE_DIR))
}

fn salt() -> Vec<u8> {
    let dir = state_dir();
    let loaded =
        File::open("/dev/urandom").and_then(|mut r| identity::load_or_create_salt(&dir, &mut r));
    match loaded {
        Ok(salt) => salt,
        Err(err) => {
            // Never overwrite a salt we cannot read: the ids are not stable this run.
            eprintln!(
                "ruya-inputd: machine salt in {} unusable ({err}); device ids are not stable until it is fixed",
                dir.display()
            );
            let mut buf = vec![0u8; identity::SALT_LEN];
            if let Err(err) = File::open("/dev/urandom").and_then(|mut r| r.read_exact(&mut buf)) {
                eprintln!("ruya-inputd: no random salt either: {err}");
            }
            buf
        }
    }
}

fn watch_udev(shared: Arc<Shared>, wake: mpsc::Sender<()>) {
    let monitor = match sys::Monitor::open() {
        Ok(m) => m,
        Err(err) => {
            return eprintln!(
                "ruya-inputd: no udev monitor ({err}): virtual pads get their ACL after {} s only",
                crate::routing::UDEV_FALLBACK.as_secs()
            )
        }
    };
    loop {
        let msg = match monitor.recv() {
            Ok(m) => m,
            Err(err) => {
                eprintln!("ruya-inputd: udev monitor: {err}");
                thread::sleep(Duration::from_secs(1));
                continue;
            }
        };
        let Some(ev) = parse_monitor_message(&msg) else {
            continue;
        };
        if !ev.is_event_node() {
            continue;
        }
        shared.with(|r| r.udev_event(&ev));
        if ev.action == "add" {
            let _ = wake.send(());
        }
    }
}

fn run_ff(shared: Arc<Shared>, calls: mpsc::Receiver<FfCall>) {
    for call in calls {
        match call {
            FfCall::Upload {
                id,
                effect,
                rumble,
                reply,
            } => {
                let result = shared.with(|r| r.ff_upload(id, effect, &rumble));
                let _ = reply.send(result);
            }
            FfCall::Play { id, effect, value } => shared.with(|r| r.ff_play(id, effect, value)),
            FfCall::Erase { id, effect } => shared.with(|r| r.ff_erase(id, effect)),
        }
    }
}

pub fn run() -> io::Result<()> {
    let notifier = Notifier::from_env();
    let (ff_tx, ff_rx) = mpsc::channel();
    let physicals: Physicals = Arc::default();
    let backend = LinuxBackend {
        nav: build_nav_keyboard()?,
        pads: HashMap::new(),
        next: 0,
        physicals: physicals.clone(),
        ff: ff_tx,
    };
    let backend: DynBackend = Box::new(backend);
    let mut router = Router::new(backend, Box::new(PasswdAccounts));
    // Controller profiles (06 section 7): <state>/profiles/<console profile>/<id>.json.
    router.set_book(Book::new(Box::new(DirStore::new(
        state_dir().join("profiles"),
    ))));
    let (shared, notices) = Shared::new(router);
    // The navigation keyboard exists: the shell can navigate as soon as pads are found.
    notifier.send("READY=1");

    let (wake_tx, wake_rx) = mpsc::channel();
    {
        let shared = shared.clone();
        thread::spawn(move || watch_udev(shared, wake_tx));
    }
    {
        let shared = shared.clone();
        thread::spawn(move || run_ff(shared, ff_rx));
    }
    {
        let shared = shared.clone();
        thread::spawn(move || loop {
            let result =
                futures_lite::future::block_on(serve(true, shared.clone(), notices.clone()));
            if let Err(err) = result {
                eprintln!("ruya-inputd: Input1 not served: {err}; retrying in 5 s");
            }
            thread::sleep(Duration::from_secs(5));
        });
    }

    let mut scanner = Scanner {
        shared: shared.clone(),
        physicals,
        salt: salt(),
        active: Arc::default(),
        ignored: HashSet::new(),
    };
    let ping = watchdog_interval(std::env::var("WATCHDOG_USEC").ok().as_deref());
    let mut last_scan: Option<Instant> = None;
    let mut last_ping = Instant::now();
    loop {
        let now = Instant::now();
        if last_scan.map_or(true, |t| now.duration_since(t) >= RESCAN_INTERVAL) {
            scanner.scan();
            last_scan = Some(now);
        }
        // Takes the router lock: the watchdog ping below proves the loop and the lock are alive.
        shared.with(|r| r.tick(now));
        if ping.is_some_and(|p| now.duration_since(last_ping) >= p) {
            notifier.send("WATCHDOG=1");
            last_ping = now;
        }
        let tick = if shared.with(|r| r.testing()) {
            TEST_TICK
        } else {
            TICK
        };
        match wake_rx.recv_timeout(tick) {
            // A new event node (udev has processed it, its ACL is set): scan now.
            Ok(()) => last_scan = None,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => thread::sleep(TICK),
        }
    }
}
