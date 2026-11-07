//! systemd-timedated over its D-Bus API (system bus, `org.freedesktop.timedate1`), with zbus.
//! Linux only. `SetTimezone` is authorised by polkit for the user the service runs as
//! (`image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-time.rules`), so it is called with
//! `interactive = false`: nobody is there to type a password on a TV.

use futures_lite::future;
use zbus::zvariant::OwnedValue;
use zbus::Connection;

use crate::time::Timedate;

pub const TIMEDATE: &str = "org.freedesktop.timedate1";
const PATH: &str = "/org/freedesktop/timedate1";
const IFACE: &str = "org.freedesktop.timedate1";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

pub struct TimedateClient {
    conn: Connection,
}

impl TimedateClient {
    pub fn connect() -> Result<Self, String> {
        future::block_on(Connection::system())
            .map(|conn| TimedateClient { conn })
            .map_err(|e| e.to_string())
    }

    async fn property(&self, name: &str) -> Result<OwnedValue, zbus::Error> {
        let reply = self
            .conn
            .call_method(
                Some(TIMEDATE),
                PATH,
                Some(PROPERTIES),
                "Get",
                &(IFACE, name),
            )
            .await?;
        reply.body().deserialize::<OwnedValue>()
    }
}

impl Timedate for TimedateClient {
    fn timezone(&self) -> Result<String, String> {
        let value = future::block_on(self.property("Timezone")).map_err(|e| e.to_string())?;
        String::try_from(value).map_err(|e| e.to_string())
    }

    fn ntp_synchronised(&self) -> Result<bool, String> {
        let value =
            future::block_on(self.property("NTPSynchronized")).map_err(|e| e.to_string())?;
        bool::try_from(value).map_err(|e| e.to_string())
    }

    fn list_timezones(&self) -> Result<Vec<String>, String> {
        let reply = future::block_on(self.conn.call_method(
            Some(TIMEDATE),
            PATH,
            Some(IFACE),
            "ListTimezones",
            &(),
        ))
        .map_err(|e| e.to_string())?;
        reply
            .body()
            .deserialize::<Vec<String>>()
            .map_err(|e| e.to_string())
    }

    fn set_timezone(&self, name: &str) -> Result<(), String> {
        future::block_on(self.conn.call_method(
            Some(TIMEDATE),
            PATH,
            Some(IFACE),
            "SetTimezone",
            &(name, false),
        ))
        .map(|_| ())
        .map_err(|e| e.to_string())
    }
}
