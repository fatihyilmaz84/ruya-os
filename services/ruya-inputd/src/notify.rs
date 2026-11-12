//! `sd_notify` without libsystemd: `READY=1` once the navigation keyboard exists, `WATCHDOG=1`
//! from the event loop (06-input.md §8.1: `WatchdogSec=5s`, so a hung loop is restarted).

use std::time::Duration;

/// How often to ping: half of `WATCHDOG_USEC`, as sd_watchdog_enabled(3) advises.
pub fn watchdog_interval(usec: Option<&str>) -> Option<Duration> {
    let usec: u64 = usec?.trim().parse().ok()?;
    (usec > 0).then(|| Duration::from_micros(usec / 2))
}

pub struct Notifier {
    #[cfg(target_os = "linux")]
    target: Option<(
        std::os::unix::net::UnixDatagram,
        std::os::unix::net::SocketAddr,
    )>,
}

impl Notifier {
    /// From `NOTIFY_SOCKET`; a no-op when it is unset (run by hand, `--session`).
    pub fn from_env() -> Notifier {
        #[cfg(target_os = "linux")]
        {
            use std::os::linux::net::SocketAddrExt;
            use std::os::unix::net::{SocketAddr, UnixDatagram};
            let target = std::env::var("NOTIFY_SOCKET").ok().and_then(|path| {
                let addr = match path.strip_prefix('@') {
                    Some(name) => SocketAddr::from_abstract_name(name.as_bytes()).ok()?,
                    None => SocketAddr::from_pathname(&path).ok()?,
                };
                Some((UnixDatagram::unbound().ok()?, addr))
            });
            Notifier { target }
        }
        #[cfg(not(target_os = "linux"))]
        Notifier {}
    }

    pub fn send(&self, state: &str) {
        #[cfg(target_os = "linux")]
        if let Some((socket, addr)) = &self.target {
            if let Err(err) = socket.send_to_addr(state.as_bytes(), addr) {
                eprintln!("ruya-inputd: sd_notify {state} failed: {err}");
            }
        }
        #[cfg(not(target_os = "linux"))]
        let _ = state;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_watchdog_is_pinged_at_half_its_timeout() {
        assert_eq!(
            watchdog_interval(Some("5000000")),
            Some(Duration::from_millis(2500))
        );
        assert_eq!(watchdog_interval(Some("0")), None);
        assert_eq!(watchdog_interval(Some("x")), None);
        assert_eq!(watchdog_interval(None), None);
    }
}
