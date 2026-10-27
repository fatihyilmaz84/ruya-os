//! NetworkManager over its own D-Bus API (system bus, `org.freedesktop.NetworkManager`), with
//! zbus. No `nmcli` output to parse: the API is stable, and it announces changes by signals.
//! The pure mappings (saved connections, failure reasons) are here and tested on any host; the
//! calls are Linux-only. Passwords go into one D-Bus call and into no log line or error.

use std::collections::HashMap;

use zbus::zvariant::OwnedValue;

use crate::network::{ConnectError, Saved, Security};

/// `GetSettings` of a connection: section → key → value.
pub type Settings = HashMap<String, HashMap<String, OwnedValue>>;

/// A saved Wi-Fi connection from its settings; `None` for anything else (ethernet, VPN, …).
pub fn saved_from_settings(settings: &Settings) -> Option<Saved> {
    use zbus::zvariant::Value;

    let kind = settings.get("connection")?.get("type")?;
    if !matches!(&**kind, Value::Str(s) if s.as_str() == "802-11-wireless") {
        return None;
    }
    let Value::Array(bytes) = &**settings.get("802-11-wireless")?.get("ssid")? else {
        return None;
    };
    let raw: Vec<u8> = bytes
        .iter()
        .filter_map(|b| match b {
            Value::U8(b) => Some(*b),
            _ => None,
        })
        .collect();
    let ssid = String::from_utf8_lossy(&raw).into_owned();
    let security = match settings
        .get("802-11-wireless-security")
        .and_then(|s| s.get("key-mgmt"))
        .map(|k| &**k)
    {
        None => Security::Open,
        Some(Value::Str(k)) if k.as_str() == "wpa-eap" || k.as_str() == "ieee8021x" => {
            Security::Enterprise
        }
        // wpa-psk, sae; WEP ("none") is not offered either, but a saved one shows as WPA.
        Some(_) => Security::WpaPsk,
    };
    Some(Saved { ssid, security })
}

/// Why a Wi-Fi device went to `failed` (NMDeviceStateReason). A key that was not accepted shows
/// as `NO_SECRETS` (no agent to ask) or `SUPPLICANT_DISCONNECT` (the access point said no).
pub fn failure_from_reason(reason: u32) -> ConnectError {
    match reason {
        7 | 8 => ConnectError::WrongPassword,
        other => ConnectError::Failed(format!("activation failed, reason {other}")),
    }
}

#[cfg(target_os = "linux")]
pub use linux::NmClient;

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use std::time::{Duration, Instant};

    use async_io::Timer;
    use futures_lite::{future, StreamExt};
    use serde::de::DeserializeOwned;
    use zbus::zvariant::{ObjectPath, OwnedValue, Type, Value};
    use zbus::{Connection, MatchRule, MessageStream};

    use super::{failure_from_reason, saved_from_settings, Settings};
    use crate::network::{
        AccessPoint, ConnectError, Link, NetworkManager, Primary, Raw, Saved, Security,
    };

    const NM: &str = "org.freedesktop.NetworkManager";
    const NM_PATH: &str = "/org/freedesktop/NetworkManager";
    const NM_IFACE: &str = "org.freedesktop.NetworkManager";
    const SETTINGS_PATH: &str = "/org/freedesktop/NetworkManager/Settings";
    const SETTINGS_IFACE: &str = "org.freedesktop.NetworkManager.Settings";
    const SETTINGS_CONNECTION: &str = "org.freedesktop.NetworkManager.Settings.Connection";
    const DEVICE: &str = "org.freedesktop.NetworkManager.Device";
    const WIRELESS: &str = "org.freedesktop.NetworkManager.Device.Wireless";
    const ACCESS_POINT: &str = "org.freedesktop.NetworkManager.AccessPoint";
    const ACTIVE: &str = "org.freedesktop.NetworkManager.Connection.Active";
    const IP4: &str = "org.freedesktop.NetworkManager.IP4Config";
    const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

    const DEVICE_ETHERNET: u32 = 1;
    const DEVICE_WIFI: u32 = 2;
    const DEVICE_ACTIVATED: u32 = 100;
    const DEVICE_FAILED: u32 = 120;
    const AP_SAE: u32 = 0x400;
    const AP_PSK: u32 = 0x100;

    /// How long a join may take before it counts as failed.
    const JOIN_TIMEOUT: Duration = Duration::from_secs(45);

    type Dict = HashMap<String, OwnedValue>;

    pub struct NmClient {
        conn: Connection,
    }

    // The property helpers read plain values out of a `GetAll` result; a missing or odd entry
    // reads as empty, never as an error (NetworkManager versions differ in what they offer).
    fn num(d: &Dict, key: &str) -> u32 {
        match d.get(key).map(|v| &**v) {
            Some(Value::U32(n)) => *n,
            Some(Value::U8(n)) => u32::from(*n),
            _ => 0,
        }
    }

    fn path(d: &Dict, key: &str) -> String {
        match d.get(key).map(|v| &**v) {
            Some(Value::ObjectPath(p)) => p.as_str().to_owned(),
            _ => "/".to_owned(),
        }
    }

    fn paths(d: &Dict, key: &str) -> Vec<String> {
        match d.get(key).map(|v| &**v) {
            Some(Value::Array(a)) => a
                .iter()
                .filter_map(|p| match p {
                    Value::ObjectPath(p) => Some(p.as_str().to_owned()),
                    _ => None,
                })
                .collect(),
            _ => Vec::new(),
        }
    }

    fn ssid_of(d: &Dict) -> String {
        match d.get("Ssid").map(|v| &**v) {
            Some(Value::Array(a)) => {
                let raw: Vec<u8> = a
                    .iter()
                    .filter_map(|b| match b {
                        Value::U8(b) => Some(*b),
                        _ => None,
                    })
                    .collect();
                String::from_utf8_lossy(&raw).into_owned()
            }
            _ => String::new(),
        }
    }

    fn object_path(p: &str) -> Result<ObjectPath<'_>, String> {
        ObjectPath::try_from(p).map_err(|e| e.to_string())
    }

    struct Found {
        device: String,
        /// "/" when only a saved connection is known (out of range).
        ap: String,
        sae_only: bool,
    }

    impl NmClient {
        pub fn connect() -> Result<Self, String> {
            future::block_on(Connection::system())
                .map(|conn| NmClient { conn })
                .map_err(|e| e.to_string())
        }

        async fn call<B, R>(
            &self,
            path: &str,
            iface: &str,
            method: &str,
            body: &B,
        ) -> Result<R, String>
        where
            B: serde::Serialize + zbus::zvariant::DynamicType,
            R: DeserializeOwned + Type,
        {
            let reply = self
                .conn
                .call_method(Some(NM), path, Some(iface), method, body)
                .await
                .map_err(|e| e.to_string())?;
            reply.body().deserialize::<R>().map_err(|e| e.to_string())
        }

        async fn all(&self, path: &str, iface: &str) -> Result<Dict, String> {
            self.call(path, PROPERTIES, "GetAll", &(iface,)).await
        }

        async fn wifi_devices(&self) -> Result<Vec<String>, String> {
            let devices: Vec<zbus::zvariant::OwnedObjectPath> =
                self.call(NM_PATH, NM_IFACE, "GetDevices", &()).await?;
            let mut out = Vec::new();
            for dev in devices {
                if let Ok(d) = self.all(dev.as_str(), DEVICE).await {
                    if num(&d, "DeviceType") == DEVICE_WIFI {
                        out.push(dev.as_str().to_owned());
                    }
                }
            }
            Ok(out)
        }

        async fn saved_connections(&self) -> Result<Vec<(String, Saved)>, String> {
            let list: Vec<zbus::zvariant::OwnedObjectPath> = self
                .call(SETTINGS_PATH, SETTINGS_IFACE, "ListConnections", &())
                .await?;
            let mut out = Vec::new();
            for c in list {
                // A connection can vanish between the list and the read.
                let Ok(settings) = self
                    .call::<_, Settings>(c.as_str(), SETTINGS_CONNECTION, "GetSettings", &())
                    .await
                else {
                    continue;
                };
                if let Some(saved) = saved_from_settings(&settings) {
                    out.push((c.as_str().to_owned(), saved));
                }
            }
            Ok(out)
        }

        async fn access_point(&self, ap: &str, active_ap: &str) -> Option<AccessPoint> {
            let d = self.all(ap, ACCESS_POINT).await.ok()?;
            let security = Security::from_ap_flags(
                num(&d, "Flags"),
                num(&d, "WpaFlags"),
                num(&d, "RsnFlags"),
            )?;
            Some(AccessPoint {
                ssid: ssid_of(&d),
                signal: num(&d, "Strength"),
                security,
                active: ap == active_ap,
            })
        }

        async fn primary(&self, active_path: &str) -> Option<Primary> {
            if active_path == "/" {
                return None;
            }
            let active = self.all(active_path, ACTIVE).await.ok()?;
            let device = paths(&active, "Devices").into_iter().next()?;
            let dev = self.all(&device, DEVICE).await.ok()?;
            let (kind, name, signal) = match num(&dev, "DeviceType") {
                DEVICE_ETHERNET => (Link::Ethernet, "Wired".to_owned(), None),
                DEVICE_WIFI => {
                    let wifi = self.all(&device, WIRELESS).await.ok()?;
                    let ap = self
                        .all(&path(&wifi, "ActiveAccessPoint"), ACCESS_POINT)
                        .await
                        .ok()?;
                    (
                        Link::Wifi,
                        ssid_of(&ap),
                        Some(num(&ap, "Strength").min(100)),
                    )
                }
                _ => return None,
            };
            Some(Primary {
                kind,
                name,
                ip: self.ip4(&path(&active, "Ip4Config")).await,
                signal,
            })
        }

        /// The first IPv4 address, "" if none yet.
        async fn ip4(&self, config: &str) -> String {
            if config == "/" {
                return String::new();
            }
            let Ok(v) = self
                .call::<_, OwnedValue>(config, PROPERTIES, "Get", &(IP4, "AddressData"))
                .await
            else {
                return String::new();
            };
            let Ok(list) = Vec::<HashMap<String, OwnedValue>>::try_from(v) else {
                return String::new();
            };
            list.into_iter()
                .next()
                .and_then(|a| match a.get("address").map(|v| &**v) {
                    Some(Value::Str(s)) => Some(s.as_str().to_owned()),
                    _ => None,
                })
                .unwrap_or_default()
        }

        async fn snapshot_async(&self) -> Result<Raw, String> {
            let nm = self.all(NM_PATH, NM_IFACE).await?;
            let mut access_points = Vec::new();
            for device in self.wifi_devices().await? {
                let Ok(wifi) = self.all(&device, WIRELESS).await else {
                    continue;
                };
                let active_ap = path(&wifi, "ActiveAccessPoint");
                for ap in paths(&wifi, "AccessPoints") {
                    // An access point can vanish between the list and the read.
                    access_points.extend(self.access_point(&ap, &active_ap).await);
                }
            }
            let saved = self
                .saved_connections()
                .await?
                .into_iter()
                .map(|(_, s)| s)
                .collect();
            Ok(Raw {
                nm_state: num(&nm, "State"),
                connectivity: num(&nm, "Connectivity"),
                primary: self.primary(&path(&nm, "PrimaryConnection")).await,
                access_points,
                saved,
            })
        }

        async fn scan_async(&self) -> Result<(), String> {
            for device in self.wifi_devices().await? {
                let options: HashMap<&str, Value<'_>> = HashMap::new();
                // NetworkManager refuses a scan right after another one; the result of the
                // last one is still fine, so that is not an error.
                let _ = self
                    .call::<_, ()>(&device, WIRELESS, "RequestScan", &(options,))
                    .await;
            }
            Ok(())
        }

        /// The device and access point to join `ssid` on: the strongest access point with
        /// that name on any Wi-Fi device.
        async fn find(&self, ssid: &str) -> Result<Option<Found>, String> {
            let mut best: Option<(u32, Found)> = None;
            for device in self.wifi_devices().await? {
                let Ok(wifi) = self.all(&device, WIRELESS).await else {
                    continue;
                };
                for ap in paths(&wifi, "AccessPoints") {
                    let Ok(d) = self.all(&ap, ACCESS_POINT).await else {
                        continue;
                    };
                    if ssid_of(&d) != ssid {
                        continue;
                    }
                    let strength = num(&d, "Strength");
                    if best.as_ref().map_or(true, |(s, _)| strength > *s) {
                        let keys = num(&d, "WpaFlags") | num(&d, "RsnFlags");
                        best = Some((
                            strength,
                            Found {
                                device: device.clone(),
                                ap,
                                sae_only: keys & AP_SAE != 0 && keys & AP_PSK == 0,
                            },
                        ));
                    }
                }
            }
            Ok(best.map(|(_, f)| f))
        }

        async fn connect_async(
            &self,
            ssid: &str,
            password: Option<&str>,
        ) -> Result<(), ConnectError> {
            let failed = ConnectError::Failed;
            let found = self.find(ssid).await.map_err(failed)?;
            let saved = self
                .saved_connections()
                .await
                .map_err(ConnectError::Failed)?
                .into_iter()
                .find(|(_, s)| s.ssid == ssid)
                .map(|(p, _)| p);

            let (device, ap, sae_only) = match (&found, self.wifi_devices().await) {
                (Some(f), _) => (f.device.clone(), f.ap.clone(), f.sae_only),
                // Saved but out of range: NetworkManager will say whether it can still join.
                (None, Ok(devices)) if saved.is_some() && !devices.is_empty() => {
                    (devices[0].clone(), "/".to_owned(), false)
                }
                _ => return Err(ConnectError::NotFound),
            };

            // Subscribe before starting, so no state change is missed.
            let rule = MatchRule::builder()
                .msg_type(zbus::message::Type::Signal)
                .sender(NM)
                .and_then(|b| b.path(device.as_str()))
                .and_then(|b| b.interface(DEVICE))
                .and_then(|b| b.member("StateChanged"))
                .map(|b| b.build())
                .map_err(|e| ConnectError::Failed(e.to_string()))?;
            let mut stream = MessageStream::for_match_rule(rule, &self.conn, None)
                .await
                .map_err(|e| ConnectError::Failed(e.to_string()))?;

            let device_path = object_path(&device).map_err(ConnectError::Failed)?;
            let ap_path = object_path(&ap).map_err(ConnectError::Failed)?;
            let created: Option<String> = match &saved {
                Some(connection) => {
                    let connection = object_path(connection).map_err(ConnectError::Failed)?;
                    self.call::<_, zbus::zvariant::OwnedObjectPath>(
                        NM_PATH,
                        NM_IFACE,
                        "ActivateConnection",
                        &(connection, device_path, ap_path),
                    )
                    .await
                    .map_err(ConnectError::Failed)?;
                    None
                }
                None => {
                    let settings = new_connection(ssid, password, sae_only);
                    let (connection, _active): (
                        zbus::zvariant::OwnedObjectPath,
                        zbus::zvariant::OwnedObjectPath,
                    ) = self
                        .call(
                            NM_PATH,
                            NM_IFACE,
                            "AddAndActivateConnection",
                            &(settings, device_path, ap_path),
                        )
                        .await
                        .map_err(ConnectError::Failed)?;
                    Some(connection.as_str().to_owned())
                }
            };

            let outcome = wait_for_activation(&mut stream).await;
            if outcome.is_err() {
                // A join that failed saves nothing (the contract), a saved network stays.
                if let Some(connection) = created {
                    let _ = self
                        .call::<_, ()>(&connection, SETTINGS_CONNECTION, "Delete", &())
                        .await;
                }
            }
            outcome
        }

        async fn forget_async(&self, ssid: &str) -> Result<(), String> {
            for (connection, saved) in self.saved_connections().await? {
                if saved.ssid == ssid {
                    self.call::<_, ()>(&connection, SETTINGS_CONNECTION, "Delete", &())
                        .await?;
                }
            }
            Ok(())
        }
    }

    /// A new connection: WPA2/3-Personal with a password, open without one. `sae_only` for an
    /// access point that offers WPA3 only.
    fn new_connection<'a>(
        ssid: &'a str,
        password: Option<&'a str>,
        sae_only: bool,
    ) -> HashMap<&'static str, HashMap<&'static str, Value<'a>>> {
        let mut settings = HashMap::new();
        settings.insert(
            "connection",
            HashMap::from([
                ("type", Value::from("802-11-wireless")),
                ("id", Value::from(ssid)),
                ("autoconnect", Value::from(true)),
            ]),
        );
        settings.insert(
            "802-11-wireless",
            HashMap::from([("ssid", Value::from(ssid.as_bytes().to_vec()))]),
        );
        if let Some(password) = password {
            settings.insert(
                "802-11-wireless-security",
                HashMap::from([
                    (
                        "key-mgmt",
                        Value::from(if sae_only { "sae" } else { "wpa-psk" }),
                    ),
                    ("psk", Value::from(password)),
                ]),
            );
        }
        settings
    }

    /// Reads the device's `StateChanged` signals until it is activated or failed. Other
    /// transitions are not final: switching networks first takes the old connection down.
    async fn wait_for_activation(stream: &mut MessageStream) -> Result<(), ConnectError> {
        enum Event {
            Message(Option<zbus::Message>),
            Timeout,
        }
        let deadline = Instant::now() + JOIN_TIMEOUT;
        loop {
            let event = future::or(
                async { Event::Message(stream.next().await.and_then(Result::ok)) },
                async {
                    Timer::at(deadline).await;
                    Event::Timeout
                },
            )
            .await;
            let Event::Message(Some(message)) = event else {
                return Err(ConnectError::Failed("timed out or lost the bus".to_owned()));
            };
            // (new state, old state, reason)
            let Ok((state, _, reason)) = message.body().deserialize::<(u32, u32, u32)>() else {
                continue;
            };
            match state {
                DEVICE_ACTIVATED => return Ok(()),
                DEVICE_FAILED => return Err(failure_from_reason(reason)),
                _ => {}
            }
        }
    }

    impl NetworkManager for NmClient {
        fn snapshot(&self) -> Result<Raw, String> {
            future::block_on(self.snapshot_async())
        }

        fn scan(&self) -> Result<(), String> {
            future::block_on(self.scan_async())
        }

        fn connect(&self, ssid: &str, password: Option<&str>) -> Result<(), ConnectError> {
            future::block_on(self.connect_async(ssid, password))
        }

        fn forget(&self, ssid: &str) -> Result<(), String> {
            future::block_on(self.forget_async(ssid))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::Value;

    fn own(v: Value<'_>) -> OwnedValue {
        OwnedValue::try_from(v).expect("no file descriptors")
    }

    fn settings(kind: &str, ssid: &str, key_mgmt: Option<&str>) -> Settings {
        let mut s = Settings::new();
        s.insert(
            "connection".to_owned(),
            HashMap::from([("type".to_owned(), own(Value::from(kind)))]),
        );
        s.insert(
            "802-11-wireless".to_owned(),
            HashMap::from([(
                "ssid".to_owned(),
                own(Value::from(ssid.as_bytes().to_vec())),
            )]),
        );
        if let Some(k) = key_mgmt {
            s.insert(
                "802-11-wireless-security".to_owned(),
                HashMap::from([("key-mgmt".to_owned(), own(Value::from(k)))]),
            );
        }
        s
    }

    #[test]
    fn saved_wifi_connections() {
        let open = saved_from_settings(&settings("802-11-wireless", "Cafe", None));
        assert_eq!(
            open,
            Some(Saved {
                ssid: "Cafe".to_owned(),
                security: Security::Open
            })
        );
        let psk = saved_from_settings(&settings("802-11-wireless", "Home", Some("wpa-psk")));
        assert_eq!(psk.map(|s| s.security), Some(Security::WpaPsk));
        let sae = saved_from_settings(&settings("802-11-wireless", "Home", Some("sae")));
        assert_eq!(sae.map(|s| s.security), Some(Security::WpaPsk));
        let eap = saved_from_settings(&settings("802-11-wireless", "Work", Some("wpa-eap")));
        assert_eq!(eap.map(|s| s.security), Some(Security::Enterprise));
    }

    #[test]
    fn other_connection_types_are_not_wifi() {
        assert_eq!(
            saved_from_settings(&settings("802-3-ethernet", "x", None)),
            None
        );
        assert_eq!(saved_from_settings(&Settings::new()), None);
    }

    #[test]
    fn failure_reasons() {
        // NO_SECRETS, SUPPLICANT_DISCONNECT
        assert_eq!(failure_from_reason(7), ConnectError::WrongPassword);
        assert_eq!(failure_from_reason(8), ConnectError::WrongPassword);
        assert!(matches!(failure_from_reason(53), ConnectError::Failed(_)));
        assert!(matches!(failure_from_reason(0), ConnectError::Failed(_)));
    }
}
