//! ruya-inputd (Phase 0): reads every connected gamepad and re-emits navigation as
//! keyboard events on a virtual uinput device, so the shell only has to handle keys.
//!
//! Deliberately does NOT grab the physical devices: games still see the real pad.
//! Shell/game input arbitration is ADR-003 (InputPlumber) and replaces this in Phase 1.

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
mod mapping;

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
fn main() {
    if let Err(err) = linux::run() {
        eprintln!("ruya-inputd: fatal: {err}");
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("ruya-inputd only runs on Linux");
    std::process::exit(1);
}
