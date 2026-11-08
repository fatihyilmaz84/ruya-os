use std::collections::HashSet;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use evdev::uinput::{VirtualDevice, VirtualDeviceBuilder};
use evdev::{AbsoluteAxisType, AttributeSet, Device, EventType, InputEvent, InputEventKind, Key};

use crate::mapping::{Axis, Button, KeyBoard, KeyEvent, Mapper, NavKey};

const RESCAN_INTERVAL: Duration = Duration::from_secs(2);
const VIRTUAL_NAME: &str = "RuyaOS Navigation";

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

fn button_from_key(key: Key) -> Option<Button> {
    Some(match key {
        Key::BTN_SOUTH => Button::South,
        Key::BTN_EAST => Button::East,
        Key::BTN_START => Button::Start,
        Key::BTN_MODE => Button::Mode,
        Key::BTN_TL => Button::ShoulderLeft,
        Key::BTN_TR => Button::ShoulderRight,
        Key::BTN_DPAD_UP => Button::DpadUp,
        Key::BTN_DPAD_DOWN => Button::DpadDown,
        Key::BTN_DPAD_LEFT => Button::DpadLeft,
        Key::BTN_DPAD_RIGHT => Button::DpadRight,
        _ => return None,
    })
}

fn is_gamepad(device: &Device) -> bool {
    device
        .supported_keys()
        .is_some_and(|keys| keys.contains(Key::BTN_SOUTH))
}

fn build_virtual_keyboard() -> io::Result<VirtualDevice> {
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
    VirtualDeviceBuilder::new()?
        .name(VIRTUAL_NAME)
        .with_keys(&keys)?
        .build()
}

/// The shared virtual keyboard and the count of pads holding each key. One lock covers both,
/// so counting a pad's events and writing them out cannot interleave with another pad's.
struct Output {
    device: VirtualDevice,
    board: KeyBoard,
}

fn write_keys(device: &mut VirtualDevice, events: &[KeyEvent]) {
    if events.is_empty() {
        return;
    }
    let batch: Vec<InputEvent> = events
        .iter()
        .map(|&(key, pressed)| {
            InputEvent::new(EventType::KEY, nav_to_key(key).code(), pressed as i32)
        })
        .collect();
    if let Err(err) = device.emit(&batch) {
        eprintln!("ruya-inputd: emit failed: {err}");
    }
}

/// A poisoned lock (another pump panicked) must not stop the others from releasing keys.
fn lock(output: &Mutex<Output>) -> std::sync::MutexGuard<'_, Output> {
    output
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn emit(output: &Mutex<Output>, events: &[KeyEvent]) {
    let mut out = lock(output);
    let keys = out.board.route(events);
    write_keys(&mut out.device, &keys);
}

/// One pad's state. Dropping it, on any way out of `pump` (read error, node gone, a panic
/// unwinding the thread), releases every key the pad still holds on the shared keyboard.
struct Pad {
    name: String,
    mapper: Mapper,
    output: Arc<Mutex<Output>>,
    gone: String,
}

impl Drop for Pad {
    fn drop(&mut self) {
        let held = self.mapper.held_keys();
        let mut out = lock(&self.output);
        let keys = out.board.pad_gone(&mut self.mapper);
        write_keys(&mut out.device, &keys);
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
    }
}

/// Takes a path out of the served set when its pump thread ends, however it ends.
struct Serving {
    active: Arc<Mutex<HashSet<PathBuf>>>,
    path: PathBuf,
}

impl Drop for Serving {
    fn drop(&mut self) {
        self.active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.path);
    }
}

/// Reads one gamepad until it disappears (unplug -> read error).
fn pump(mut device: Device, path: PathBuf, output: Arc<Mutex<Output>>) {
    let name = device.name().unwrap_or("unknown").to_owned();
    eprintln!("ruya-inputd: using {name} ({})", path.display());

    let abs_info = device.get_abs_state().ok();
    let range = |axis: AbsoluteAxisType| {
        abs_info
            .as_ref()
            .map(|info| {
                let i = &info[axis.0 as usize];
                (i.minimum, i.maximum)
            })
            .unwrap_or((-32768, 32767))
    };
    let (x_min, x_max) = range(AbsoluteAxisType::ABS_X);
    let (y_min, y_max) = range(AbsoluteAxisType::ABS_Y);

    let mut pad = Pad {
        name,
        mapper: Mapper::default(),
        output,
        gone: "thread ended".to_owned(),
    };
    loop {
        let events = match device.fetch_events() {
            Ok(events) => events,
            Err(err) => {
                pad.gone = err.to_string();
                return;
            }
        };
        for event in events {
            let mapper = &mut pad.mapper;
            let out = match event.kind() {
                // value 2 = autorepeat; the compositor/client handles repeat itself.
                InputEventKind::Key(key) if event.value() != 2 => match button_from_key(key) {
                    Some(button) => mapper.button(button, event.value() == 1),
                    None => continue,
                },
                InputEventKind::AbsAxis(axis) => match axis {
                    AbsoluteAxisType::ABS_HAT0X => mapper.hat(Axis::Horizontal, event.value()),
                    AbsoluteAxisType::ABS_HAT0Y => mapper.hat(Axis::Vertical, event.value()),
                    AbsoluteAxisType::ABS_X => {
                        mapper.stick(Axis::Horizontal, event.value(), x_min, x_max)
                    }
                    AbsoluteAxisType::ABS_Y => {
                        mapper.stick(Axis::Vertical, event.value(), y_min, y_max)
                    }
                    _ => continue,
                },
                _ => continue,
            };
            emit(&pad.output, &out);
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

pub fn run() -> io::Result<()> {
    let output = Arc::new(Mutex::new(Output {
        device: build_virtual_keyboard()?,
        board: KeyBoard::default(),
    }));
    // Paths currently served by a pump thread; a thread removes its path when it exits.
    let active: Arc<Mutex<HashSet<PathBuf>>> = Arc::default();
    // Paths already checked and found not to be gamepads.
    let mut ignored: HashSet<PathBuf> = HashSet::new();

    loop {
        let nodes = event_nodes();
        ignored.retain(|p| nodes.contains(p));

        for path in nodes {
            if ignored.contains(&path) || active.lock().unwrap().contains(&path) {
                continue;
            }
            match Device::open(&path) {
                Ok(device) if is_gamepad(&device) => {
                    active.lock().unwrap().insert(path.clone());
                    let (output, active) = (Arc::clone(&output), Arc::clone(&active));
                    thread::spawn(move || {
                        let _serving = Serving {
                            active,
                            path: path.clone(),
                        };
                        pump(device, path, output);
                    });
                }
                Ok(_) => {
                    ignored.insert(path);
                }
                // Permission errors or a node that vanished mid-scan: retry next round.
                Err(_) => {}
            }
        }
        thread::sleep(RESCAN_INTERVAL);
    }
}
