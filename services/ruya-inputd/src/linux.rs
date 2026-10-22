use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use evdev::uinput::{VirtualDevice, VirtualDeviceBuilder};
use evdev::{AbsoluteAxisType, AttributeSet, Device, EventType, InputEvent, InputEventKind, Key};

use crate::mapping::{Axis, Button, KeyEvent, Mapper, NavKey};

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

fn emit(output: &Mutex<VirtualDevice>, events: &[KeyEvent]) {
    if events.is_empty() {
        return;
    }
    let batch: Vec<InputEvent> = events
        .iter()
        .map(|&(key, pressed)| {
            InputEvent::new(EventType::KEY, nav_to_key(key).code(), pressed as i32)
        })
        .collect();
    if let Err(err) = output.lock().unwrap().emit(&batch) {
        eprintln!("ruya-inputd: emit failed: {err}");
    }
}

/// Reads one gamepad until it disappears (unplug -> read error).
fn pump(mut device: Device, path: PathBuf, output: Arc<Mutex<VirtualDevice>>) {
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

    let mut mapper = Mapper::default();
    loop {
        let events = match device.fetch_events() {
            Ok(events) => events,
            Err(err) => {
                eprintln!("ruya-inputd: {name} gone: {err}");
                return;
            }
        };
        for event in events {
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
            emit(&output, &out);
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
    let output = Arc::new(Mutex::new(build_virtual_keyboard()?));
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
                        pump(device, path.clone(), output);
                        active.lock().unwrap().remove(Path::new(&path));
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
