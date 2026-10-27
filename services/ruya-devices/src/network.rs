//! The network rules of spec 03 §2.5: overall state, the primary connection, the Wi-Fi list
//! (one entry per SSID), and the status of `Connect`/`Forget`. No I/O except through the
//! `NetworkManager` trait; the service never sees a password after handing it to that trait.

use std::sync::{Mutex, MutexGuard};

/// Overall connectivity of the contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Disconnected,
    Connecting,
    Connected,
    /// Linked, but no internet.
    Limited,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Disconnected => "disconnected",
            State::Connecting => "connecting",
            State::Connected => "connected",
            State::Limited => "limited",
        }
    }

    /// From NetworkManager's `State` (NMState) and `Connectivity` (NMConnectivityState).
    /// Only global reachability with working (or unknown, i.e. unchecked) connectivity counts as
    /// connected; local-only and site-only links, a captive portal and a failed check are limited.
    pub fn from_nm(nm_state: u32, connectivity: u32) -> State {
        match nm_state {
            // 40 connecting; 30 disconnecting is on its way to disconnected.
            40 => State::Connecting,
            50 | 60 => State::Limited,
            70 => match connectivity {
                // 1 none, 2 portal, 3 limited
                1..=3 => State::Limited,
                _ => State::Connected,
            },
            _ => State::Disconnected,
        }
    }
}

/// Status strings of the contract (stable API).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    UnknownNetwork,
    WrongPassword,
    Unsupported,
    Invalid,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::UnknownNetwork => "unknown-network",
            Status::WrongPassword => "wrong-password",
            Status::Unsupported => "unsupported",
            Status::Invalid => "invalid",
            Status::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Security {
    Open,
    WpaPsk,
    Enterprise,
}

impl Security {
    pub fn as_str(self) -> &'static str {
        match self {
            Security::Open => "open",
            Security::WpaPsk => "wpa-psk",
            Security::Enterprise => "enterprise",
        }
    }

    /// From an access point's `Flags`, `WpaFlags` and `RsnFlags` (NM_802_11_AP_*). `None` for
    /// what the console cannot join and does not list: WEP and other pre-WPA schemes.
    pub fn from_ap_flags(flags: u32, wpa: u32, rsn: u32) -> Option<Security> {
        const PRIVACY: u32 = 0x1;
        const PSK: u32 = 0x100;
        const EAP: u32 = 0x200;
        const SAE: u32 = 0x400;
        const OWE: u32 = 0x800;
        const OWE_TM: u32 = 0x1000;
        const EAP_SUITE_B: u32 = 0x2000;

        let keys = wpa | rsn;
        if keys & (PSK | SAE) != 0 {
            Some(Security::WpaPsk)
        } else if keys & (EAP | EAP_SUITE_B) != 0 {
            Some(Security::Enterprise)
        } else if keys & (OWE | OWE_TM) != 0 {
            // Opportunistic encryption: joins without a password.
            Some(Security::Open)
        } else if keys == 0 && flags & PRIVACY == 0 {
            Some(Security::Open)
        } else {
            None
        }
    }
}

/// Which kind of link the console uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Link {
    Ethernet,
    Wifi,
}

impl Link {
    pub fn as_str(self) -> &'static str {
        match self {
            Link::Ethernet => "ethernet",
            Link::Wifi => "wifi",
        }
    }
}

/// The connection the console uses (`Primary` of the contract).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Primary {
    pub kind: Link,
    /// "Wired" or the SSID.
    pub name: String,
    /// IPv4 address, "" if none yet.
    pub ip: String,
    /// 0-100, Wi-Fi only.
    pub signal: Option<u32>,
}

/// One access point as NetworkManager reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccessPoint {
    pub ssid: String,
    pub signal: u32,
    pub security: Security,
    /// The connected one.
    pub active: bool,
}

/// A saved Wi-Fi connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Saved {
    pub ssid: String,
    pub security: Security,
}

/// What NetworkManager says right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Raw {
    pub nm_state: u32,
    pub connectivity: u32,
    pub primary: Option<Primary>,
    pub access_points: Vec<AccessPoint>,
    pub saved: Vec<Saved>,
}

/// One entry of `ListWifi`. The id is the SSID: entries are unique by SSID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wifi {
    pub ssid: String,
    pub signal: u32,
    pub security: Security,
    pub known: bool,
    pub active: bool,
}

impl Wifi {
    pub fn id(&self) -> &str {
        &self.ssid
    }
}

/// Why `NetworkManager::connect` failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectError {
    /// The key was rejected (a new one, or a saved one that no longer works).
    WrongPassword,
    /// The network is neither in range nor saved any more.
    NotFound,
    /// Anything else; the text goes to the log and must not contain the password.
    Failed(String),
}

/// The side effects: NetworkManager itself. A fake serves tests and `--session`; on Linux
/// `networkmanager::NmClient` talks to NetworkManager's D-Bus API. Methods block, and `connect`
/// may take tens of seconds: the adapter calls them off its executor.
pub trait NetworkManager: Send + Sync {
    fn snapshot(&self) -> Result<Raw, String>;
    fn scan(&self) -> Result<(), String>;
    /// `password` is only given for a secured network that is not saved. A successful join
    /// saves the network.
    fn connect(&self, ssid: &str, password: Option<&str>) -> Result<(), ConnectError>;
    /// Deletes every saved connection of that SSID (which disconnects it when active).
    fn forget(&self, ssid: &str) -> Result<(), String>;
}

/// What a `refresh` changed, so the adapter knows which signals to emit.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// `State` or `Primary`.
    pub state: bool,
    pub networks: bool,
}

impl Changes {
    pub fn any(&self) -> bool {
        self.state || self.networks
    }
}

#[derive(Default)]
struct View {
    loaded: bool,
    state: Option<State>,
    primary: Option<Primary>,
    wifi: Vec<Wifi>,
}

pub struct Network<N: NetworkManager> {
    nm: N,
    view: Mutex<View>,
}

/// The Wi-Fi list: one entry per SSID (the strongest access point wins, `active` if any of them
/// is connected), saved networks out of range at signal 0, strongest first (equal signals by
/// name, so the order is stable). Hidden (empty) SSIDs are left out.
pub fn wifi_list(access_points: &[AccessPoint], saved: &[Saved]) -> Vec<Wifi> {
    let mut list: Vec<Wifi> = Vec::new();
    for ap in access_points.iter().filter(|a| !a.ssid.is_empty()) {
        match list.iter_mut().find(|w| w.ssid == ap.ssid) {
            Some(w) => {
                w.active |= ap.active;
                if ap.signal > w.signal {
                    w.signal = ap.signal;
                    w.security = ap.security;
                }
            }
            None => list.push(Wifi {
                ssid: ap.ssid.clone(),
                signal: ap.signal.min(100),
                security: ap.security,
                known: false,
                active: ap.active,
            }),
        }
    }
    for s in saved.iter().filter(|s| !s.ssid.is_empty()) {
        match list.iter_mut().find(|w| w.ssid == s.ssid) {
            Some(w) => w.known = true,
            None => list.push(Wifi {
                ssid: s.ssid.clone(),
                signal: 0,
                security: s.security,
                known: true,
                active: false,
            }),
        }
    }
    list.sort_by(|a, b| b.signal.cmp(&a.signal).then_with(|| a.ssid.cmp(&b.ssid)));
    list
}

impl<N: NetworkManager> Network<N> {
    pub fn new(nm: N) -> Self {
        Network {
            nm,
            view: Mutex::new(View::default()),
        }
    }

    fn view(&self) -> MutexGuard<'_, View> {
        // A poisoned lock only means another call panicked; the view is plain data.
        self.view.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reads NetworkManager. The first call only takes over the state (no change to announce).
    pub fn refresh(&self) -> Result<Changes, String> {
        let raw = self.nm.snapshot()?;
        let state = State::from_nm(raw.nm_state, raw.connectivity);
        // No primary link, no primary: while disconnected or still connecting the contract
        // says empty.
        let primary = match state {
            State::Disconnected | State::Connecting => None,
            _ => raw.primary,
        };
        let wifi = wifi_list(&raw.access_points, &raw.saved);

        let mut view = self.view();
        let first = !view.loaded;
        let changes = Changes {
            state: view.state != Some(state) || view.primary != primary,
            networks: view.wifi != wifi,
        };
        view.loaded = true;
        view.state = Some(state);
        view.primary = primary;
        view.wifi = wifi;
        Ok(if first { Changes::default() } else { changes })
    }

    pub fn state(&self) -> State {
        self.view().state.unwrap_or(State::Disconnected)
    }

    pub fn primary(&self) -> Option<Primary> {
        self.view().primary.clone()
    }

    pub fn list_wifi(&self) -> Vec<Wifi> {
        self.view().wifi.clone()
    }

    pub fn scan(&self) -> Status {
        match self.nm.scan() {
            Ok(()) => Status::Ok,
            Err(_) => Status::Failed,
        }
    }

    pub fn connect(&self, id: &str, password: &str) -> Status {
        let Some(net) = self.find(id) else {
            return Status::UnknownNetwork;
        };
        let password = match net.security {
            Security::Enterprise => return Status::Unsupported,
            // A saved network is joined with its saved key; an open one has none.
            Security::Open => None,
            Security::WpaPsk if net.known => None,
            Security::WpaPsk if password.is_empty() => return Status::Invalid,
            Security::WpaPsk => Some(password),
        };
        match self.nm.connect(&net.ssid, password) {
            Ok(()) => Status::Ok,
            Err(ConnectError::WrongPassword) => Status::WrongPassword,
            Err(ConnectError::NotFound) => Status::UnknownNetwork,
            Err(ConnectError::Failed(_)) => Status::Failed,
        }
    }

    pub fn forget(&self, id: &str) -> Status {
        match self.find(id) {
            Some(net) if net.known => match self.nm.forget(&net.ssid) {
                Ok(()) => Status::Ok,
                Err(_) => Status::Failed,
            },
            _ => Status::UnknownNetwork,
        }
    }

    fn find(&self, id: &str) -> Option<Wifi> {
        self.view().wifi.iter().find(|w| w.id() == id).cloned()
    }
}

/// A scripted NetworkManager for tests and `--session` development. `password` is the key the
/// fake network accepts.
pub struct FakeNetworkManager {
    inner: Mutex<FakeInner>,
}

struct FakeInner {
    raw: Raw,
    password: String,
    /// The last password `connect` was given (so tests can check it arrived, and that it is
    /// only given when it should be).
    last_password: Option<Option<String>>,
    fail_scan: bool,
}

impl FakeNetworkManager {
    /// A wired link and three networks: open, WPA (saved), WPA with strong signal, enterprise.
    pub fn new(password: &str) -> Self {
        let ap = |ssid: &str, signal, security| AccessPoint {
            ssid: ssid.to_owned(),
            signal,
            security,
            active: false,
        };
        FakeNetworkManager {
            inner: Mutex::new(FakeInner {
                raw: Raw {
                    nm_state: 70,
                    connectivity: 4,
                    primary: Some(Primary {
                        kind: Link::Ethernet,
                        name: "Wired".to_owned(),
                        ip: "192.168.1.20".to_owned(),
                        signal: None,
                    }),
                    access_points: vec![
                        ap("Livingroom", 82, Security::WpaPsk),
                        ap("CoffeeShop", 47, Security::Open),
                        ap("Neighbour", 35, Security::WpaPsk),
                        ap("Office", 60, Security::Enterprise),
                    ],
                    saved: vec![Saved {
                        ssid: "Livingroom".to_owned(),
                        security: Security::WpaPsk,
                    }],
                },
                password: password.to_owned(),
                last_password: None,
                fail_scan: false,
            }),
        }
    }

    fn inner(&self) -> MutexGuard<'_, FakeInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Edits what the next `snapshot` returns.
    pub fn set_raw(&self, edit: impl FnOnce(&mut Raw)) {
        edit(&mut self.inner().raw);
    }

    pub fn set_scan_fails(&self, fail: bool) {
        self.inner().fail_scan = fail;
    }

    pub fn last_password(&self) -> Option<Option<String>> {
        self.inner().last_password.clone()
    }
}

impl NetworkManager for FakeNetworkManager {
    fn snapshot(&self) -> Result<Raw, String> {
        Ok(self.inner().raw.clone())
    }

    fn scan(&self) -> Result<(), String> {
        if self.inner().fail_scan {
            Err("scan refused".to_owned())
        } else {
            Ok(())
        }
    }

    fn connect(&self, ssid: &str, password: Option<&str>) -> Result<(), ConnectError> {
        let mut inner = self.inner();
        inner.last_password = Some(password.map(str::to_owned));
        let saved = inner.raw.saved.iter().any(|s| s.ssid == ssid);
        let Some(security) = inner
            .raw
            .access_points
            .iter()
            .find(|a| a.ssid == ssid)
            .map(|a| a.security)
            .or_else(|| {
                inner
                    .raw
                    .saved
                    .iter()
                    .find(|s| s.ssid == ssid)
                    .map(|s| s.security)
            })
        else {
            return Err(ConnectError::NotFound);
        };
        if security == Security::WpaPsk && !saved && password != Some(inner.password.as_str()) {
            return Err(ConnectError::WrongPassword);
        }
        for ap in &mut inner.raw.access_points {
            ap.active = ap.ssid == ssid;
        }
        if !saved {
            inner.raw.saved.push(Saved {
                ssid: ssid.to_owned(),
                security,
            });
        }
        let signal = inner
            .raw
            .access_points
            .iter()
            .find(|a| a.ssid == ssid)
            .map(|a| a.signal);
        inner.raw.primary = Some(Primary {
            kind: Link::Wifi,
            name: ssid.to_owned(),
            ip: "192.168.1.21".to_owned(),
            signal,
        });
        Ok(())
    }

    fn forget(&self, ssid: &str) -> Result<(), String> {
        let mut inner = self.inner();
        inner.raw.saved.retain(|s| s.ssid != ssid);
        let was_active = inner
            .raw
            .access_points
            .iter()
            .any(|a| a.ssid == ssid && a.active);
        if was_active {
            for ap in &mut inner.raw.access_points {
                ap.active = false;
            }
            inner.raw.primary = None;
            inner.raw.nm_state = 20;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn net() -> Network<FakeNetworkManager> {
        let n = Network::new(FakeNetworkManager::new("secret-key"));
        n.refresh().expect("fake never fails");
        n
    }

    fn ap(ssid: &str, signal: u32, active: bool) -> AccessPoint {
        AccessPoint {
            ssid: ssid.to_owned(),
            signal,
            security: Security::WpaPsk,
            active,
        }
    }

    #[test]
    fn state_follows_networkmanager() {
        // asleep, disconnected, disconnecting
        for s in [0, 10, 20, 30] {
            assert_eq!(State::from_nm(s, 4), State::Disconnected);
        }
        assert_eq!(State::from_nm(40, 0), State::Connecting);
        // linked locally or site-wide only: no internet
        assert_eq!(State::from_nm(50, 0), State::Limited);
        assert_eq!(State::from_nm(60, 4), State::Limited);
        assert_eq!(State::from_nm(70, 4), State::Connected);
        assert_eq!(State::from_nm(70, 0), State::Connected, "unchecked is fine");
        for c in [1, 2, 3] {
            assert_eq!(State::from_nm(70, c), State::Limited, "connectivity {c}");
        }
    }

    #[test]
    fn security_from_access_point_flags() {
        assert_eq!(Security::from_ap_flags(0, 0, 0), Some(Security::Open));
        assert_eq!(Security::from_ap_flags(1, 0, 0), None, "WEP");
        assert_eq!(
            Security::from_ap_flags(1, 0x1, 0x8),
            None,
            "ciphers, no key management"
        );
        assert_eq!(
            Security::from_ap_flags(1, 0x188, 0x188),
            Some(Security::WpaPsk),
            "PSK"
        );
        assert_eq!(
            Security::from_ap_flags(1, 0, 0x400),
            Some(Security::WpaPsk),
            "WPA3 SAE"
        );
        assert_eq!(
            Security::from_ap_flags(1, 0, 0x200),
            Some(Security::Enterprise)
        );
        assert_eq!(
            Security::from_ap_flags(1, 0, 0x2000),
            Some(Security::Enterprise)
        );
        assert_eq!(
            Security::from_ap_flags(1, 0, 0x300),
            Some(Security::WpaPsk),
            "PSK next to 802.1X: a password works"
        );
        assert_eq!(
            Security::from_ap_flags(1, 0, 0x800),
            Some(Security::Open),
            "OWE"
        );
    }

    #[test]
    fn list_dedupes_by_ssid_strongest_wins() {
        let list = wifi_list(
            &[
                ap("Home", 40, false),
                ap("Home", 71, false),
                ap("Home", 55, false),
            ],
            &[],
        );
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].signal, 71);
    }

    #[test]
    fn active_flag_survives_a_stronger_neighbour_access_point() {
        let list = wifi_list(&[ap("Home", 30, true), ap("Home", 90, false)], &[]);
        assert_eq!(list.len(), 1);
        assert!(list[0].active);
        assert_eq!(list[0].signal, 90);
    }

    #[test]
    fn list_marks_known_and_adds_saved_out_of_range() {
        let saved = [
            Saved {
                ssid: "Home".to_owned(),
                security: Security::WpaPsk,
            },
            Saved {
                ssid: "Holiday".to_owned(),
                security: Security::WpaPsk,
            },
        ];
        let list = wifi_list(&[ap("Home", 60, false), ap("Other", 80, false)], &saved);
        let names: Vec<&str> = list.iter().map(|w| w.ssid.as_str()).collect();
        assert_eq!(
            names,
            ["Other", "Home", "Holiday"],
            "strongest first, absent last"
        );
        assert!(!list[0].known);
        assert!(list[1].known);
        assert!(list[2].known);
        assert_eq!(list[2].signal, 0);
    }

    #[test]
    fn list_order_is_stable_for_equal_signals_and_skips_hidden() {
        let list = wifi_list(
            &[ap("b", 50, false), ap("", 99, false), ap("a", 50, false)],
            &[],
        );
        let names: Vec<&str> = list.iter().map(|w| w.ssid.as_str()).collect();
        assert_eq!(names, ["a", "b"]);
    }

    #[test]
    fn first_refresh_announces_nothing_later_ones_do() {
        let n = Network::new(FakeNetworkManager::new("pw"));
        assert_eq!(n.refresh(), Ok(Changes::default()));
        assert_eq!(n.state(), State::Connected);
        assert_eq!(n.refresh(), Ok(Changes::default()), "nothing changed");

        n.nm.set_raw(|r| r.connectivity = 3);
        assert_eq!(
            n.refresh(),
            Ok(Changes {
                state: true,
                networks: false
            })
        );
        assert_eq!(n.state(), State::Limited);

        n.nm.set_raw(|r| r.access_points[0].signal = 20);
        assert_eq!(
            n.refresh(),
            Ok(Changes {
                state: false,
                networks: true
            })
        );
    }

    #[test]
    fn primary_is_empty_unless_a_link_is_up() {
        let n = net();
        assert_eq!(n.primary().map(|p| p.name), Some("Wired".to_owned()));
        n.nm.set_raw(|r| r.nm_state = 40);
        n.refresh().expect("fake never fails");
        assert_eq!(n.state(), State::Connecting);
        assert_eq!(n.primary(), None);
        n.nm.set_raw(|r| r.nm_state = 20);
        n.refresh().expect("fake never fails");
        assert_eq!(n.state(), State::Disconnected);
        assert_eq!(n.primary(), None);
    }

    #[test]
    fn connect_to_an_unknown_id() {
        assert_eq!(net().connect("Nowhere", "x"), Status::UnknownNetwork);
    }

    #[test]
    fn connect_refuses_enterprise() {
        let n = net();
        assert_eq!(n.connect("Office", "x"), Status::Unsupported);
        assert_eq!(n.nm.last_password(), None, "never reached NetworkManager");
    }

    #[test]
    fn connect_to_a_new_secured_network_needs_a_password() {
        let n = net();
        assert_eq!(n.connect("Neighbour", ""), Status::Invalid);
        assert_eq!(n.nm.last_password(), None);
        assert_eq!(n.connect("Neighbour", "nope"), Status::WrongPassword);
        assert_eq!(n.connect("Neighbour", "secret-key"), Status::Ok);
        assert_eq!(n.nm.last_password(), Some(Some("secret-key".to_owned())));
    }

    #[test]
    fn a_successful_join_saves_and_activates() {
        let n = net();
        assert_eq!(n.connect("Neighbour", "secret-key"), Status::Ok);
        n.refresh().expect("fake never fails");
        let w = n.list_wifi();
        let joined = w.iter().find(|w| w.ssid == "Neighbour").expect("listed");
        assert!(joined.known && joined.active);
        assert_eq!(n.primary().map(|p| p.kind), Some(Link::Wifi));
    }

    #[test]
    fn a_saved_network_ignores_the_password_given() {
        let n = net();
        assert_eq!(n.connect("Livingroom", ""), Status::Ok);
        assert_eq!(
            n.nm.last_password(),
            Some(None),
            "joined with the saved key"
        );
        assert_eq!(n.connect("Livingroom", "whatever"), Status::Ok);
        assert_eq!(n.nm.last_password(), Some(None));
    }

    #[test]
    fn an_open_network_ignores_the_password_given() {
        let n = net();
        assert_eq!(n.connect("CoffeeShop", "ignored"), Status::Ok);
        assert_eq!(n.nm.last_password(), Some(None));
    }

    #[test]
    fn a_saved_key_that_stopped_working_is_a_wrong_password() {
        struct Rejecting;
        impl NetworkManager for Rejecting {
            fn snapshot(&self) -> Result<Raw, String> {
                Ok(Raw {
                    nm_state: 20,
                    connectivity: 1,
                    primary: None,
                    access_points: vec![],
                    saved: vec![Saved {
                        ssid: "Home".to_owned(),
                        security: Security::WpaPsk,
                    }],
                })
            }
            fn scan(&self) -> Result<(), String> {
                Ok(())
            }
            fn connect(&self, _: &str, _: Option<&str>) -> Result<(), ConnectError> {
                Err(ConnectError::WrongPassword)
            }
            fn forget(&self, _: &str) -> Result<(), String> {
                Err("boom".to_owned())
            }
        }
        let n = Network::new(Rejecting);
        n.refresh().expect("fine");
        assert_eq!(n.connect("Home", ""), Status::WrongPassword);
        assert_eq!(n.forget("Home"), Status::Failed);
    }

    #[test]
    fn network_manager_errors_map_to_failed_and_unknown() {
        struct Broken(ConnectError);
        impl NetworkManager for Broken {
            fn snapshot(&self) -> Result<Raw, String> {
                FakeNetworkManager::new("x").snapshot()
            }
            fn scan(&self) -> Result<(), String> {
                Err("no".to_owned())
            }
            fn connect(&self, _: &str, _: Option<&str>) -> Result<(), ConnectError> {
                Err(self.0.clone())
            }
            fn forget(&self, _: &str) -> Result<(), String> {
                Ok(())
            }
        }
        let n = Network::new(Broken(ConnectError::Failed("x".to_owned())));
        n.refresh().expect("fine");
        assert_eq!(n.connect("Livingroom", ""), Status::Failed);
        assert_eq!(n.scan(), Status::Failed);
        let gone = Network::new(Broken(ConnectError::NotFound));
        gone.refresh().expect("fine");
        assert_eq!(gone.connect("Livingroom", ""), Status::UnknownNetwork);
    }

    #[test]
    fn forget_needs_a_saved_network() {
        let n = net();
        assert_eq!(n.forget("Nowhere"), Status::UnknownNetwork);
        assert_eq!(n.forget("CoffeeShop"), Status::UnknownNetwork, "not saved");
        assert_eq!(n.forget("Livingroom"), Status::Ok);
        n.refresh().expect("fake never fails");
        let w = n.list_wifi();
        assert!(
            !w.iter()
                .find(|w| w.ssid == "Livingroom")
                .expect("in range")
                .known
        );
    }

    #[test]
    fn forgetting_the_active_network_disconnects() {
        let n = net();
        assert_eq!(n.connect("Livingroom", ""), Status::Ok);
        n.refresh().expect("fake never fails");
        assert_eq!(n.forget("Livingroom"), Status::Ok);
        let changes = n.refresh().expect("fake never fails");
        assert!(changes.state && changes.networks);
        assert_eq!(n.state(), State::Disconnected);
    }

    #[test]
    fn scan_status() {
        let n = net();
        assert_eq!(n.scan(), Status::Ok);
        n.nm.set_scan_fails(true);
        assert_eq!(n.scan(), Status::Failed);
    }
}
