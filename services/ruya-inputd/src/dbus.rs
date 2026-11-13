//! Thin zbus adapter for `org.ruyaos.Input1` (api/dbus/org.ruyaos.Input1.xml): the Devices,
//! capabilities, button test, Routing and controller profile members. Converts types, calls the
//! core and emits what the core announces. No rules.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use futures_lite::StreamExt;
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection, MatchRule, MessageStream};

use crate::book::Summary;
use crate::routing::{Backend, DeviceRecord, Notice, Router, Status};

pub const BUS_NAME: &str = "org.ruyaos.Input1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Input1";

type Dict = HashMap<String, OwnedValue>;
/// One capability of `GetCapabilities`, `(sbbbb)`: name, hardware, driver, available, output.
type CapTuple = (String, bool, bool, bool, bool);

pub type DynBackend = Box<dyn Backend + Send>;

impl Backend for DynBackend {
    fn nav_keys(&mut self, events: &[crate::mapping::KeyEvent]) {
        (**self).nav_keys(events)
    }
    fn create_virtual(
        &mut self,
        pad: crate::routing::PadKey,
        spec: &crate::routing::VirtualSpec,
    ) -> Result<crate::routing::Created, String> {
        (**self).create_virtual(pad, spec)
    }
    fn destroy_virtual(&mut self, id: crate::routing::VirtualId) {
        (**self).destroy_virtual(id)
    }
    fn write_virtual(&mut self, id: crate::routing::VirtualId, events: &[crate::pad::OutEvent]) {
        (**self).write_virtual(id, events)
    }
    fn node_of(&mut self, sysname: &str) -> Option<String> {
        (**self).node_of(sysname)
    }
    fn read_acl(&mut self, node: &str) -> Option<Vec<u8>> {
        (**self).read_acl(node)
    }
    fn write_acl(&mut self, node: &str, acl: &[u8]) -> Result<(), String> {
        (**self).write_acl(node, acl)
    }
    fn ff_upload(
        &mut self,
        pad: crate::routing::PadKey,
        physical_id: i16,
        rumble: &crate::pad::Rumble,
    ) -> Result<i16, i32> {
        (**self).ff_upload(pad, physical_id, rumble)
    }
    fn ff_play(&mut self, pad: crate::routing::PadKey, physical_id: i16, value: i32) {
        (**self).ff_play(pad, physical_id, value)
    }
    fn ff_erase(&mut self, pad: crate::routing::PadKey, physical_id: i16) {
        (**self).ff_erase(pad, physical_id)
    }
}

pub type SharedRouter = Router<DynBackend>;

/// The router, shared by the pad threads, the udev monitor and the bus. Every call drains the
/// router's notices: journal lines are printed, the rest go to the signal task.
pub struct Shared {
    router: Mutex<SharedRouter>,
    notices: async_channel::Sender<Notice>,
}

impl Shared {
    pub fn new(router: SharedRouter) -> (Arc<Shared>, async_channel::Receiver<Notice>) {
        let (tx, rx) = async_channel::unbounded();
        (
            Arc::new(Shared {
                router: Mutex::new(router),
                notices: tx,
            }),
            rx,
        )
    }

    /// A poisoned lock (a thread panicked) must not stop the others from releasing keys.
    fn lock(&self) -> MutexGuard<'_, SharedRouter> {
        self.router
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn with<R>(&self, f: impl FnOnce(&mut SharedRouter) -> R) -> R {
        let mut router = self.lock();
        let out = f(&mut router);
        for notice in router.take_notices() {
            match notice {
                Notice::Journal(line) => eprintln!("ruya-inputd: {line}"),
                other => {
                    let _ = self.notices.try_send(other);
                }
            }
        }
        out
    }
}

fn record(d: &DeviceRecord) -> Dict {
    let entries = vec![
        ("id", Value::from(d.id.clone())),
        ("instance", Value::from(d.instance.clone())),
        ("name", Value::from(d.name.clone())),
        ("family", Value::from(d.family.clone())),
        ("connection", Value::from(d.connection.clone())),
        ("model", Value::from(d.model.clone())),
        ("layout", Value::from(d.layout.clone())),
        ("battery", Value::from(d.battery)),
        ("charging", Value::from(d.charging)),
        ("slot", Value::from(d.slot)),
        ("profile", Value::from(d.profile.clone())),
        ("routed", Value::from(d.routed)),
    ];
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

/// A profile summary of `ListProfiles` (the keys of the XML header).
fn summary(s: &Summary) -> Dict {
    let entries = vec![
        ("id", Value::from(s.id.clone())),
        ("name", Value::from(s.name.clone())),
        ("scope", Value::from(s.scope.clone())),
        ("scope_id", Value::from(s.scope_id.clone())),
        ("inherits", Value::from(s.inherits.clone())),
        ("builtin", Value::from(s.builtin)),
        ("assigned", Value::from(s.assigned)),
        ("global_slot", Value::from(s.global_slot.clone())),
        ("match_family", Value::from(s.match_family.clone())),
        ("match_device", Value::from(s.match_device.clone())),
        ("layout", Value::from(s.layout.clone())),
        ("remapped", Value::from(s.remapped)),
        ("left_stick_changed", Value::from(s.left_stick_changed)),
        ("right_stick_changed", Value::from(s.right_stick_changed)),
        ("changed", Value::from(s.changed)),
    ];
    entries
        .into_iter()
        .filter_map(|(k, v)| OwnedValue::try_from(v).ok().map(|v| (k.to_owned(), v)))
        .collect()
}

/// Whether `name` still has an owner on the bus. Only a definite "no owner" answer counts as
/// gone; any other error keeps the route (the NameOwnerChanged follower still covers it).
async fn caller_present(connection: &Connection, name: &str) -> bool {
    let Ok(bus) = zbus::fdo::DBusProxy::new(connection).await else {
        return true;
    };
    let Ok(bus_name) = zbus::names::BusName::try_from(name) else {
        return false;
    };
    !matches!(
        bus.get_name_owner(bus_name).await,
        Err(zbus::fdo::Error::NameHasNoOwner(_))
    )
}

pub struct InputIface {
    shared: Arc<Shared>,
}

impl InputIface {
    pub fn new(shared: Arc<Shared>) -> Self {
        InputIface { shared }
    }
}

#[interface(name = "org.ruyaos.Input1")]
impl InputIface {
    fn list_devices(&self) -> Vec<Dict> {
        self.shared
            .with(|r| r.devices().iter().map(record).collect())
    }

    fn get_capabilities(&self, device_id: &str) -> (String, Vec<CapTuple>) {
        let (status, caps) = self.shared.with(|r| r.capabilities(device_id));
        let caps = caps
            .iter()
            .map(|c| {
                (
                    c.name.to_owned(),
                    c.hardware,
                    c.driver,
                    c.available,
                    c.output,
                )
            })
            .collect();
        (status.as_str().to_owned(), caps)
    }

    async fn start_test(
        &self,
        device_id: &str,
        hold_left_stick: bool,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let caller = header.sender().map(|s| s.to_string()).unwrap_or_default();
        let status = self
            .shared
            .with(|r| r.start_test(device_id, hold_left_stick, &caller, Instant::now()));
        if status == Status::Ok && !caller_present(connection, &caller).await {
            self.shared.with(|r| r.caller_left(&caller, Instant::now()));
        }
        status.as_str().to_owned()
    }

    fn stop_test(&self, device_id: &str) -> String {
        self.shared
            .with(|r| r.stop_test(device_id))
            .as_str()
            .to_owned()
    }

    #[zbus(signal)]
    async fn test_input(
        emitter: &SignalEmitter<'_>,
        device_id: &str,
        input: &str,
        value: i32,
        source: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn test_ended(
        emitter: &SignalEmitter<'_>,
        device_id: &str,
        reason: &str,
    ) -> zbus::Result<()>;

    async fn set_route(
        &self,
        route: &str,
        instance: &str,
        app_id: &str,
        profile: &str,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] connection: &Connection,
    ) -> String {
        let caller = header.sender().map(|s| s.to_string()).unwrap_or_default();
        let status = self
            .shared
            .with(|r| r.set_route(route, instance, app_id, profile, &caller, Instant::now()));
        // The caller may have left the bus before we followed it (its NameOwnerChanged came
        // first): ask the bus, and lock the route if it is gone.
        if status == Status::Ok && !caller_present(connection, &caller).await {
            self.shared.with(|r| r.caller_left(&caller, Instant::now()));
        }
        status.as_str().to_owned()
    }

    #[zbus(out_args("status", "profiles"))]
    fn list_profiles(&self, profile: &str) -> (String, Vec<Dict>) {
        let (status, list) = self.shared.with(|r| r.list_profiles(profile));
        (
            status.as_str().to_owned(),
            list.iter().map(summary).collect(),
        )
    }

    #[zbus(out_args("status", "json"))]
    fn get_profile(&self, profile: &str, profile_id: &str) -> (String, String) {
        let (status, json) = self.shared.with(|r| r.get_profile(profile, profile_id));
        (status.as_str().to_owned(), json)
    }

    #[zbus(out_args("status", "profile_id", "errors"))]
    fn save_profile(&self, profile: &str, json: &str) -> (String, String, Vec<String>) {
        let (status, id, errors) = self.shared.with(|r| r.save_profile(profile, json));
        (status.as_str().to_owned(), id, errors)
    }

    #[zbus(out_args("status", "errors"))]
    fn validate_profile(&self, json: &str) -> (String, Vec<String>) {
        let (status, errors) = SharedRouter::validate_profile(json);
        (status.as_str().to_owned(), errors)
    }

    fn delete_profile(&self, profile: &str, profile_id: &str) -> String {
        self.shared
            .with(|r| r.delete_profile(profile, profile_id))
            .as_str()
            .to_owned()
    }

    fn assign_profile(
        &self,
        profile: &str,
        scope: &str,
        scope_id: &str,
        profile_id: &str,
    ) -> String {
        self.shared
            .with(|r| r.assign_profile(profile, scope, scope_id, profile_id))
            .as_str()
            .to_owned()
    }

    #[zbus(out_args("status", "json", "chain"))]
    fn get_effective_profile(
        &self,
        profile: &str,
        device_id: &str,
        app_id: &str,
    ) -> (String, String, Vec<String>) {
        let (status, json, chain) = self
            .shared
            .with(|r| r.effective_profile(profile, device_id, app_id));
        (status.as_str().to_owned(), json, chain)
    }

    #[zbus(signal)]
    async fn profiles_changed(emitter: &SignalEmitter<'_>, profile: &str) -> zbus::Result<()>;

    #[zbus(property)]
    fn route(&self) -> String {
        self.shared.with(|r| r.route().as_str().to_owned())
    }

    fn set_confirm_button(&self, profile: &str, mode: &str) -> String {
        self.shared
            .with(|r| r.set_confirm_button(profile, mode))
            .as_str()
            .to_owned()
    }

    /// The signed-in profile's Confirm button: "family" | "south" | "east".
    #[zbus(property)]
    fn confirm_button(&self) -> String {
        self.shared.with(|r| r.confirm_button().to_owned())
    }

    #[zbus(signal)]
    async fn active_input_changed(
        emitter: &SignalEmitter<'_>,
        device_id: &str,
        family: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn device_added(emitter: &SignalEmitter<'_>, device: Dict) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn device_changed(emitter: &SignalEmitter<'_>, device: Dict) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn device_removed(
        emitter: &SignalEmitter<'_>,
        device_id: &str,
        instance: &str,
    ) -> zbus::Result<()>;

    /// `RouteChanged` (named apart from the `Route` property's own change helper).
    #[zbus(signal, name = "RouteChanged")]
    async fn route_switched(
        emitter: &SignalEmitter<'_>,
        route: &str,
        instance: &str,
    ) -> zbus::Result<()>;
}

/// Emits what the router announced, in order.
pub async fn announce(connection: Connection, notices: async_channel::Receiver<Notice>) {
    let iface = match connection
        .object_server()
        .interface::<_, InputIface>(OBJECT_PATH)
        .await
    {
        Ok(iface) => iface,
        Err(err) => return eprintln!("ruya-inputd: no Input1 object to signal from: {err}"),
    };
    while let Ok(notice) = notices.recv().await {
        let emitter = iface.signal_emitter();
        let result = match &notice {
            Notice::DeviceAdded(d) => InputIface::device_added(emitter, record(d)).await,
            Notice::DeviceChanged(d) => InputIface::device_changed(emitter, record(d)).await,
            Notice::DeviceRemoved { id, instance } => {
                InputIface::device_removed(emitter, id, instance).await
            }
            Notice::RouteChanged { route, instance } => {
                let props = iface.get().await.route_changed(emitter).await;
                let sig = InputIface::route_switched(emitter, route, instance).await;
                props.and(sig)
            }
            Notice::TestInput {
                device_id,
                input,
                value,
                source,
            } => InputIface::test_input(emitter, device_id, input, *value, source).await,
            Notice::TestEnded { device_id, reason } => {
                InputIface::test_ended(emitter, device_id, reason).await
            }
            Notice::ProfilesChanged { profile } => {
                InputIface::profiles_changed(emitter, profile).await
            }
            Notice::ConfirmButtonChanged => iface.get().await.confirm_button_changed(emitter).await,
            Notice::ActiveInput { device_id, family } => {
                InputIface::active_input_changed(emitter, device_id, family).await
            }
            Notice::Journal(_) => Ok(()),
        };
        if let Err(err) = result {
            eprintln!("ruya-inputd: emitting {notice:?} failed: {err}");
        }
    }
}

/// Owns the name, serves the object and runs the signal and caller tasks until the connection
/// ends. `system` false: the session bus (`--session`).
pub async fn serve(
    system: bool,
    shared: Arc<Shared>,
    notices: async_channel::Receiver<Notice>,
) -> zbus::Result<()> {
    let builder = if system {
        zbus::connection::Builder::system()?
    } else {
        zbus::connection::Builder::session()?
    };
    let connection = builder
        .name(BUS_NAME)?
        .serve_at(OBJECT_PATH, InputIface::new(shared.clone()))?
        .build()
        .await?;
    eprintln!("ruya-inputd: serving {BUS_NAME}");
    futures_lite::future::zip(
        announce(connection.clone(), notices),
        follow_callers(connection, shared),
    )
    .await;
    Ok(())
}

/// Follows `NameOwnerChanged`: a unique name that leaves the bus may be the route's caller.
pub async fn follow_callers(connection: Connection, shared: Arc<Shared>) {
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .map(|b| b.build());
    let Ok(rule) = rule else {
        return eprintln!("ruya-inputd: cannot follow callers");
    };
    let mut stream = match MessageStream::for_match_rule(rule, &connection, None).await {
        Ok(s) => s,
        Err(err) => return eprintln!("ruya-inputd: cannot follow callers: {err}"),
    };
    while let Some(Ok(message)) = stream.next().await {
        let Ok((name, _old, new)) = message.body().deserialize::<(String, String, String)>() else {
            continue;
        };
        if new.is_empty() && name.starts_with(':') {
            shared.with(|r| r.caller_left(&name, Instant::now()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::Value;

    #[test]
    fn a_device_record_has_the_model_key_next_to_the_family() {
        let d = DeviceRecord {
            id: "bluetooth-054c-0ce6-0123456789ab".into(),
            instance: "bluetooth-054c-0ce6-0123456789ab#1".into(),
            name: "DualSense Wireless Controller".into(),
            family: "playstation".into(),
            connection: "bluetooth".into(),
            model: "dualsense".into(),
            layout: String::new(),
            battery: -1,
            charging: false,
            slot: 0,
            profile: String::new(),
            routed: false,
        };
        let dict = record(&d);
        let text = |key: &str| match dict.get(key).map(|v| &**v) {
            Some(Value::Str(s)) => s.as_str().to_owned(),
            other => panic!("{key}: {other:?}"),
        };
        assert_eq!(text("family"), "playstation");
        assert_eq!(text("model"), "dualsense");
        assert_eq!(dict.len(), 12, "the contract's keys, no more");
    }
}
