//! UPower over its D-Bus API (system bus, `org.freedesktop.UPower`), with zbus. Linux only. An
//! absent UPower (not installed, not startable) reads as "no devices", never as an error: a
//! console without it simply shows no controller battery.

use std::collections::HashMap;

use futures_lite::future;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::Connection;

use crate::battery::{RawDevice, UPower};

pub const UPOWER: &str = "org.freedesktop.UPower";
const PATH: &str = "/org/freedesktop/UPower";
const DEVICE: &str = "org.freedesktop.UPower.Device";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

type Dict = HashMap<String, OwnedValue>;

pub struct UPowerClient {
    conn: Connection,
}

fn num(d: &Dict, key: &str) -> u32 {
    match d.get(key).map(|v| &**v) {
        Some(Value::U32(n)) => *n,
        _ => 0,
    }
}

fn text(d: &Dict, key: &str) -> String {
    match d.get(key).map(|v| &**v) {
        Some(Value::Str(s)) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn float(d: &Dict, key: &str) -> f64 {
    match d.get(key).map(|v| &**v) {
        Some(Value::F64(n)) => *n,
        _ => 0.0,
    }
}

/// Whether a bus error only says "UPower is not there" (not installed, cannot be started, gone
/// while we asked).
fn is_absent(err: &zbus::Error) -> bool {
    match err {
        zbus::Error::MethodError(name, _, _) => matches!(
            name.as_str(),
            "org.freedesktop.DBus.Error.ServiceUnknown"
                | "org.freedesktop.DBus.Error.NameHasNoOwner"
                | "org.freedesktop.DBus.Error.Spawn.ServiceNotFound"
                | "org.freedesktop.DBus.Error.Spawn.ChildExited"
                | "org.freedesktop.DBus.Error.Spawn.Failed"
                | "org.freedesktop.DBus.Error.Spawn.ExecFailed"
                | "org.freedesktop.DBus.Error.UnknownObject"
        ),
        _ => false,
    }
}

impl UPowerClient {
    pub fn connect() -> Result<Self, String> {
        future::block_on(Connection::system())
            .map(|conn| UPowerClient { conn })
            .map_err(|e| e.to_string())
    }

    async fn read(&self) -> Result<Vec<RawDevice>, zbus::Error> {
        let reply = self
            .conn
            .call_method(
                Some(UPOWER),
                PATH,
                Some("org.freedesktop.UPower"),
                "EnumerateDevices",
                &(),
            )
            .await?;
        let paths: Vec<OwnedObjectPath> = reply.body().deserialize()?;
        let mut out = Vec::new();
        for p in paths {
            // A device can vanish between the list and the read.
            let Ok(reply) = self
                .conn
                .call_method(
                    Some(UPOWER),
                    p.as_str(),
                    Some(PROPERTIES),
                    "GetAll",
                    &(DEVICE,),
                )
                .await
            else {
                continue;
            };
            let Ok(d) = reply.body().deserialize::<Dict>() else {
                continue;
            };
            out.push(RawDevice {
                id: p.as_str().to_owned(),
                kind: num(&d, "Type"),
                model: text(&d, "Model"),
                percentage: float(&d, "Percentage"),
                state: num(&d, "State"),
            });
        }
        Ok(out)
    }
}

impl UPower for UPowerClient {
    fn devices(&self) -> Result<Vec<RawDevice>, String> {
        match future::block_on(self.read()) {
            Ok(devices) => Ok(devices),
            Err(err) if is_absent(&err) => Ok(Vec::new()),
            Err(err) => Err(err.to_string()),
        }
    }
}
