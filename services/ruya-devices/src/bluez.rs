//! BlueZ over its D-Bus API (system bus, `org.bluez`), with zbus. Linux only. BlueZ not being
//! there (not installed, not startable) reads as "no adapter", never as an error. The pure
//! rules are in `bluetooth.rs`.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use blocking::unblock;
use futures_lite::future;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{interface, Connection, DBusError};

use crate::bluetooth::{
    adapter_name, AdapterInfo, AgentCall, AgentSlot, Bluez, BtError, Raw, RawAdapter, RawDevice,
    LOCAL_TIMEOUT,
};
use crate::log;

pub const BLUEZ: &str = "org.bluez";
const ADAPTER: &str = "org.bluez.Adapter1";
const DEVICE: &str = "org.bluez.Device1";
const BATTERY: &str = "org.bluez.Battery1";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const OBJECTS: &str = "org.freedesktop.DBus.ObjectManager";
const AGENT_MANAGER: &str = "org.bluez.AgentManager1";
const BLUEZ_ROOT: &str = "/org/bluez";

/// Where our agent object is served (on the connection that registers it).
const AGENT_PATH: &str = "/org/ruyaos/Devices1/Agent";
/// "Just works" only: the console can neither show nor take a PIN or a passkey.
const AGENT_CAPABILITY: &str = "NoInputNoOutput";

/// Longest the cancelling call after a timeout may take.
const UNDO_LIMIT: Duration = Duration::from_secs(2);

type Dict = HashMap<String, OwnedValue>;

pub struct BluezClient {
    conn: Connection,
    agent: AgentSlot,
}

/// The error an agent answers with to refuse.
#[derive(DBusError, Debug)]
#[zbus(prefix = "org.bluez.Error")]
enum AgentError {
    #[zbus(error)]
    ZBus(zbus::Error),
    Rejected(String),
}

/// `org.bluez.Agent1`, served only so that BlueZ can ask it. The rules are the handler's
/// (`Bluetooth::agent`); while none is set, or the window is shut, everything is refused.
struct AgentIface {
    slot: AgentSlot,
}

impl AgentIface {
    async fn ask(&self, device: &ObjectPath<'_>, uuid: Option<&str>) -> Result<(), AgentError> {
        let Some(handler) = self.slot.get().cloned() else {
            return Err(AgentError::Rejected("no handler".to_owned()));
        };
        let (device, uuid) = (device.as_str().to_owned(), uuid.map(str::to_owned));
        // The handler reads BlueZ over the bus and blocks: off this connection's executor.
        let accepted = unblock(move || {
            handler.answer(match &uuid {
                Some(uuid) => AgentCall::Service {
                    device: &device,
                    uuid,
                },
                None => AgentCall::Authorize { device: &device },
            })
        })
        .await;
        if accepted {
            Ok(())
        } else {
            Err(AgentError::Rejected("not accepted".to_owned()))
        }
    }

    fn refuse<T>() -> Result<T, AgentError> {
        // PIN and passkey pairing is not offered (B-006).
        crate::log::info("agent refused a PIN or passkey request (not offered)");
        Err(AgentError::Rejected("no PIN or passkey".to_owned()))
    }
}

#[interface(name = "org.bluez.Agent1")]
impl AgentIface {
    fn release(&self) {}

    fn request_pin_code(&self, _device: ObjectPath<'_>) -> Result<String, AgentError> {
        Self::refuse()
    }

    fn display_pin_code(&self, _device: ObjectPath<'_>, _pincode: &str) -> Result<(), AgentError> {
        Self::refuse()
    }

    fn request_passkey(&self, _device: ObjectPath<'_>) -> Result<u32, AgentError> {
        Self::refuse()
    }

    fn display_passkey(
        &self,
        _device: ObjectPath<'_>,
        _passkey: u32,
        _entered: u16,
    ) -> Result<(), AgentError> {
        Self::refuse()
    }

    async fn request_confirmation(
        &self,
        device: ObjectPath<'_>,
        _passkey: u32,
    ) -> Result<(), AgentError> {
        self.ask(&device, None).await
    }

    async fn request_authorization(&self, device: ObjectPath<'_>) -> Result<(), AgentError> {
        self.ask(&device, None).await
    }

    async fn authorize_service(
        &self,
        device: ObjectPath<'_>,
        uuid: &str,
    ) -> Result<(), AgentError> {
        self.ask(&device, Some(uuid)).await
    }

    fn cancel(&self) {}
}

fn flag(d: &Dict, key: &str) -> bool {
    matches!(d.get(key).map(|v| &**v), Some(Value::Bool(true)))
}

fn text(d: &Dict, key: &str) -> String {
    match d.get(key).map(|v| &**v) {
        Some(Value::Str(s)) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

/// The error name of a failed call; anything that is not a D-Bus error reply is a plain failure.
fn name_of(err: &zbus::Error) -> BtError {
    match err {
        zbus::Error::MethodError(name, _, _) => BtError(name.as_str().to_owned()),
        zbus::Error::FDO(e) => BtError(e.name().as_str().to_owned()),
        other => BtError(format!("org.ruyaos.Error.Io: {other}")),
    }
}

/// `/org/bluez/hci1/dev_..` -> `/org/bluez/hci1`.
fn parent_of(path: &str) -> String {
    path.rsplit_once('/')
        .map_or_else(|| path.to_owned(), |(parent, _)| parent.to_owned())
}

/// Whether `hciN` hangs off a USB bus: its sysfs path (`/sys/class/bluetooth/hci0` is a symlink
/// into the device tree) has a `usb` component. Unreadable: not USB.
fn is_usb(name: &str) -> bool {
    std::fs::canonicalize(format!("/sys/class/bluetooth/{name}"))
        .is_ok_and(|p| p.to_string_lossy().contains("/usb"))
}

/// A device's object path under the adapter that BlueZ named it with (`/org/bluez/hci0`).
fn device_path(adapter: &str, address: &str) -> String {
    format!("{adapter}/dev_{}", address.replace(':', "_"))
}

impl BluezClient {
    /// Connects to the system bus and serves the (idle) agent object on that connection; BlueZ
    /// calls an agent on the connection that registered it, so registering has to happen here
    /// too. `agent_slot` is where the core's handler goes once it exists.
    pub fn connect() -> Result<Self, String> {
        future::block_on(async {
            let conn = Connection::system().await.map_err(|e| e.to_string())?;
            let agent: AgentSlot = Arc::new(OnceLock::new());
            conn.object_server()
                .at(
                    AGENT_PATH,
                    AgentIface {
                        slot: agent.clone(),
                    },
                )
                .await
                .map_err(|e| e.to_string())?;
            Ok(BluezClient { conn, agent })
        })
    }

    pub fn agent_slot(&self) -> AgentSlot {
        self.agent.clone()
    }

    async fn call(
        &self,
        path: &str,
        iface: &str,
        member: &str,
        body: &(impl serde::Serialize + zbus::zvariant::DynamicType),
    ) -> Result<zbus::Message, BtError> {
        self.conn
            .call_method(Some(BLUEZ), path, Some(iface), member, body)
            .await
            .map_err(|e| name_of(&e))
    }

    /// Like `call`, but gives up after `timeout` and then asks BlueZ to drop what it was doing.
    async fn call_within(
        &self,
        path: &str,
        iface: &str,
        member: &str,
        undo: &str,
        timeout: Duration,
    ) -> Result<(), BtError> {
        let call = async { self.call(path, iface, member, &()).await.map(|_| ()) };
        let wait = async {
            async_io::Timer::after(timeout).await;
            Err(BtError::new(LOCAL_TIMEOUT))
        };
        let result = future::or(call, wait).await;
        if matches!(&result, Err(e) if e.0 == LOCAL_TIMEOUT) {
            // Best effort; the answer to the caller is the timeout either way.
            // It has a short limit of its own, so the whole call stays inside UNDO_LIMIT more.
            let undo_call = async {
                let _ = self.call(path, iface, undo, &()).await;
            };
            let limit = async {
                async_io::Timer::after(UNDO_LIMIT).await;
            };
            future::or(undo_call, limit).await;
        }
        result
    }

    async fn objects(&self) -> Result<HashMap<OwnedObjectPath, HashMap<String, Dict>>, BtError> {
        let reply = self.call("/", OBJECTS, "GetManagedObjects", &()).await?;
        reply
            .body()
            .deserialize()
            .map_err(|e| BtError(format!("org.ruyaos.Error.Io: {e}")))
    }

    /// Every adapter and every device of every adapter. The primary adapter is `Raw::primary`.
    async fn read(&self) -> Result<Raw, BtError> {
        let objects = match self.objects().await {
            Ok(o) => o,
            Err(e) if is_absent(&e.0) => return Ok(Raw::default()),
            Err(e) => return Err(e),
        };
        let mut paths: Vec<_> = objects.keys().collect();
        paths.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        let mut adapters = Vec::new();
        let mut devices = Vec::new();
        for p in paths {
            let ifaces = &objects[p];
            if let Some(a) = ifaces.get(ADAPTER) {
                adapters.push(AdapterInfo {
                    path: p.as_str().to_owned(),
                    usb: is_usb(adapter_name(p.as_str())),
                    address: text(a, "Address").to_uppercase(),
                    state: RawAdapter {
                        powered: flag(a, "Powered"),
                        discovering: flag(a, "Discovering"),
                        pairable: flag(a, "Pairable"),
                        discoverable: flag(a, "Discoverable"),
                    },
                });
            }
            if let Some(d) = ifaces.get(DEVICE) {
                let battery = match ifaces
                    .get(BATTERY)
                    .and_then(|b| b.get("Percentage"))
                    .map(|v| &**v)
                {
                    Some(Value::U8(p)) => Some(*p),
                    _ => None,
                };
                devices.push(RawDevice {
                    address: text(d, "Address"),
                    alias: text(d, "Alias"),
                    name: text(d, "Name"),
                    icon: text(d, "Icon"),
                    modalias: text(d, "Modalias"),
                    paired: flag(d, "Paired"),
                    bonded: flag(d, "Bonded"),
                    connected: flag(d, "Connected"),
                    trusted: flag(d, "Trusted"),
                    battery,
                    class: match d.get("Class").map(|v| &**v) {
                        Some(Value::U32(c)) => Some(*c),
                        _ => None,
                    },
                    appearance: match d.get("Appearance").map(|v| &**v) {
                        Some(Value::U16(a)) => Some(*a),
                        _ => None,
                    },
                    // `/org/bluez/hci1/dev_..` is the device of `/org/bluez/hci1`.
                    adapter: parent_of(p.as_str()),
                });
            }
        }
        Ok(Raw { adapters, devices })
    }

    async fn set(&self, path: &str, iface: &str, prop: &str, on: bool) -> Result<(), BtError> {
        self.call(path, PROPERTIES, "Set", &(iface, prop, Value::from(on)))
            .await
            .map(|_| ())
    }

    async fn set_text(
        &self,
        path: &str,
        iface: &str,
        prop: &str,
        text: &str,
    ) -> Result<(), BtError> {
        self.call(path, PROPERTIES, "Set", &(iface, prop, Value::from(text)))
            .await
            .map(|_| ())
    }
}

/// Whether a bus error only says "BlueZ is not there" (not installed, cannot be started, gone
/// while we asked).
fn is_absent(name: &str) -> bool {
    matches!(
        name,
        "org.freedesktop.DBus.Error.ServiceUnknown"
            | "org.freedesktop.DBus.Error.NameHasNoOwner"
            | "org.freedesktop.DBus.Error.Spawn.ServiceNotFound"
            | "org.freedesktop.DBus.Error.Spawn.ChildExited"
            | "org.freedesktop.DBus.Error.Spawn.Failed"
            | "org.freedesktop.DBus.Error.Spawn.ExecFailed"
            | "org.freedesktop.DBus.Error.UnknownObject"
    )
}

impl Bluez for BluezClient {
    fn snapshot(&self) -> Result<Raw, BtError> {
        future::block_on(self.read())
    }

    /// Every adapter: off for all of them; on for every one that lets itself be switched (an
    /// rfkill-blocked one refuses). The first refusal is the answer when none could be.
    fn set_powered(&self, on: bool) -> Result<(), BtError> {
        future::block_on(async {
            let raw = self.read().await?;
            if raw.adapters.is_empty() {
                return Err(BtError::new("org.bluez.Error.NotReady"));
            }
            let mut first_error = None;
            let mut switched = 0;
            for a in &raw.adapters {
                match self.set(&a.path, ADAPTER, "Powered", on).await {
                    Ok(()) => switched += 1,
                    Err(e) => {
                        log::info(&format!(
                            "{} Powered {on} failed: {}",
                            adapter_name(&a.path),
                            e.0
                        ));
                        first_error.get_or_insert(e);
                    }
                }
            }
            match first_error {
                Some(e) if switched == 0 || !on => Err(e),
                _ => Ok(()),
            }
        })
    }

    fn set_pairable(&self, adapter: &str, on: bool) -> Result<(), BtError> {
        future::block_on(self.set(adapter, ADAPTER, "Pairable", on))
    }

    fn set_discoverable(&self, adapter: &str, on: bool) -> Result<(), BtError> {
        future::block_on(self.set(adapter, ADAPTER, "Discoverable", on))
    }

    fn register_agent(&self) -> Result<(), BtError> {
        future::block_on(async {
            let path = ObjectPath::try_from(AGENT_PATH)
                .map_err(|_| BtError::new("org.bluez.Error.InvalidArguments"))?;
            match self
                .call(
                    BLUEZ_ROOT,
                    AGENT_MANAGER,
                    "RegisterAgent",
                    &(&path, AGENT_CAPABILITY),
                )
                .await
            {
                // A registration of ours that outlived a crash of ours: take it over.
                Err(e) if e.0 == "org.bluez.Error.AlreadyExists" => {}
                other => {
                    other?;
                }
            }
            self.call(BLUEZ_ROOT, AGENT_MANAGER, "RequestDefaultAgent", &(&path,))
                .await
                .map(|_| ())
        })
    }

    fn unregister_agent(&self) -> Result<(), BtError> {
        future::block_on(async {
            let path = ObjectPath::try_from(AGENT_PATH)
                .map_err(|_| BtError::new("org.bluez.Error.InvalidArguments"))?;
            match self
                .call(BLUEZ_ROOT, AGENT_MANAGER, "UnregisterAgent", &(&path,))
                .await
            {
                Err(e) if e.0 == "org.bluez.Error.DoesNotExist" => Ok(()),
                other => other.map(|_| ()),
            }
        })
    }

    fn start_discovery(&self, adapter: &str) -> Result<(), BtError> {
        future::block_on(async {
            match self.call(adapter, ADAPTER, "StartDiscovery", &()).await {
                // Someone else (or an earlier call of ours) already runs it.
                Err(e) if e.0 == "org.bluez.Error.InProgress" => Ok(()),
                other => other.map(|_| ()),
            }
        })
    }

    fn stop_discovery(&self, adapter: &str) -> Result<(), BtError> {
        future::block_on(async {
            self.call(adapter, ADAPTER, "StopDiscovery", &())
                .await
                .map(|_| ())
        })
    }

    fn pair(&self, adapter: &str, address: &str, timeout: Duration) -> Result<(), BtError> {
        future::block_on(async {
            let path = device_path(adapter, address);
            self.call_within(&path, DEVICE, "Pair", "CancelPairing", timeout)
                .await
        })
    }

    fn set_trusted(&self, adapter: &str, address: &str) -> Result<(), BtError> {
        future::block_on(async {
            self.set(&device_path(adapter, address), DEVICE, "Trusted", true)
                .await
        })
    }

    fn connect(&self, adapter: &str, address: &str, timeout: Duration) -> Result<(), BtError> {
        future::block_on(async {
            let path = device_path(adapter, address);
            self.call_within(&path, DEVICE, "Connect", "Disconnect", timeout)
                .await
        })
    }

    fn disconnect(&self, adapter: &str, address: &str) -> Result<(), BtError> {
        future::block_on(async {
            self.call(&device_path(adapter, address), DEVICE, "Disconnect", &())
                .await
                .map(|_| ())
        })
    }

    fn set_alias(&self, adapter: &str, address: &str, alias: &str) -> Result<(), BtError> {
        future::block_on(async {
            self.set_text(&device_path(adapter, address), DEVICE, "Alias", alias)
                .await
        })
    }

    fn remove(&self, adapter: &str, address: &str) -> Result<(), BtError> {
        future::block_on(async {
            let path = OwnedObjectPath::try_from(device_path(adapter, address))
                .map_err(|_| BtError::new("org.bluez.Error.InvalidArguments"))?;
            self.call(adapter, ADAPTER, "RemoveDevice", &(path,))
                .await
                .map(|_| ())
        })
    }
}
