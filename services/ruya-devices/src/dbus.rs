//! org.ruyaos.Devices1.Audio on D-Bus. Thin adapter: all rules live in `audio.rs`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedValue, Value};
use zbus::{interface, Connection};

use crate::audio::{Audio, Changes};

/// Chosen at runtime: `wpctl` on Linux, a fake in `--session` development.
pub type DynPipeWire = Box<dyn crate::audio::PipeWire>;

impl crate::audio::PipeWire for DynPipeWire {
    fn snapshot(&mut self) -> Result<crate::audio::Snapshot, String> {
        (**self).snapshot()
    }
    fn set_default(&mut self, id: &str) -> Result<(), String> {
        (**self).set_default(id)
    }
    fn set_volume(&mut self, volume: u32) -> Result<(), String> {
        (**self).set_volume(volume)
    }
    fn set_muted(&mut self, muted: bool) -> Result<(), String> {
        (**self).set_muted(muted)
    }
}

pub const BUS_NAME: &str = "org.ruyaos.Devices1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Devices1";
/// How often PipeWire is read for hot-plug and for changes made from outside.
const POLL: Duration = Duration::from_secs(1);

pub type Shared = Arc<Mutex<Audio<DynPipeWire>>>;

fn lock(shared: &Shared) -> MutexGuard<'_, Audio<DynPipeWire>> {
    // A poisoned lock only means another call panicked; the state itself is plain data.
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct AudioIface {
    audio: Shared,
}

impl AudioIface {
    pub fn new(audio: Shared) -> Self {
        AudioIface { audio }
    }
}

#[interface(name = "org.ruyaos.Devices1.Audio")]
impl AudioIface {
    fn list_sinks(&self) -> Vec<HashMap<String, OwnedValue>> {
        lock(&self.audio)
            .list_sinks()
            .into_iter()
            .map(|(s, is_default)| {
                let own = |v: Value<'_>| OwnedValue::try_from(v).ok();
                [
                    ("id", own(Value::from(s.id.clone()))),
                    ("name", own(Value::from(s.name.clone()))),
                    ("kind", own(Value::from(s.kind.as_str()))),
                    ("is_default", own(Value::from(is_default))),
                ]
                .into_iter()
                .filter_map(|(k, v)| v.map(|v| (k.to_owned(), v)))
                .collect()
            })
            .collect()
    }

    async fn set_default_sink(
        &self,
        id: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let (status, before, after) = {
            let mut audio = lock(&self.audio);
            let before = audio.default_sink().map(str::to_owned);
            let status = audio.set_default_sink(id);
            (status, before, audio.default_sink().map(str::to_owned))
        };
        if before != after {
            let _ = Self::sinks_changed(&emitter).await;
            let _ = Self::default_sink_changed(&emitter, after.unwrap_or_default()).await;
        }
        status.as_str().to_owned()
    }

    async fn set_channel_volume(
        &self,
        channel: &str,
        value: u32,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> String {
        let status = lock(&self.audio).set_channel(channel, value);
        if status == crate::Status::Ok {
            let _ = self.channel_volumes_changed(&emitter).await;
        }
        status.as_str().to_owned()
    }

    #[zbus(property)]
    fn master_volume(&self) -> u32 {
        lock(&self.audio).volume()
    }

    #[zbus(property)]
    fn set_master_volume(&mut self, value: u32) {
        let status = lock(&self.audio).set_volume(value);
        if status != crate::Status::Ok {
            eprintln!("ruya-devices: setting the volume failed");
        }
    }

    #[zbus(property)]
    fn muted(&self) -> bool {
        lock(&self.audio).muted()
    }

    #[zbus(property)]
    fn set_muted(&mut self, value: bool) {
        let status = lock(&self.audio).set_muted(value);
        if status != crate::Status::Ok {
            eprintln!("ruya-devices: setting mute failed");
        }
    }

    #[zbus(property)]
    fn channel_volumes(&self) -> HashMap<String, u32> {
        lock(&self.audio).channels().into_iter().collect()
    }

    #[zbus(signal)]
    async fn sinks_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn default_sink_changed(emitter: &SignalEmitter<'_>, id: String) -> zbus::Result<()>;
}

/// Reads PipeWire every `POLL` and turns what changed into signals. Runs forever.
pub async fn watch(connection: Connection, audio: Shared) {
    loop {
        async_io::Timer::after(POLL).await;
        let result = lock(&audio).refresh();
        match result {
            Ok(changes) if changes.any() => {
                if let Err(err) = announce(&connection, &changes).await {
                    eprintln!("ruya-devices: emitting signals failed: {err}");
                }
            }
            Ok(_) => {}
            Err(err) => eprintln!("ruya-devices: reading PipeWire failed: {err}"),
        }
    }
}

async fn announce(connection: &Connection, changes: &Changes) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, AudioIface>(OBJECT_PATH)
        .await?;
    let emitter = iface.signal_emitter();
    if changes.sinks {
        AudioIface::sinks_changed(emitter).await?;
    }
    if let Some(id) = &changes.default {
        AudioIface::default_sink_changed(emitter, id.clone()).await?;
    }
    if changes.props {
        let this = iface.get().await;
        this.master_volume_changed(emitter).await?;
        this.muted_changed(emitter).await?;
    }
    Ok(())
}
