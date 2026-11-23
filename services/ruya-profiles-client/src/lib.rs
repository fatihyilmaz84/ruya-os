//! A service's view of Profiles1 (`org.ruyaos.Profiles1`): which profiles and guests exist and
//! which one is active, read once ([`fetch`]) or followed for as long as the bus is up
//! ([`follow`]). The one copy of this client (RUY-1098): `ruya-notifications` and `ruya-platform`
//! use it; what a service does with the answer stays its own.

use std::collections::BTreeSet;
use std::future::Future;
use std::time::Duration;

use zbus::{Connection, MatchRule, MessageStream};

pub const NAME: &str = "org.ruyaos.Profiles1";
pub const PATH: &str = "/org/ruyaos/Profiles1";

/// Profiles1's active profile (`""` for nobody) and every profile id that exists: ListProfiles
/// (kept profiles) with ListGuests (live temporary guests).
pub async fn fetch(connection: &Connection) -> zbus::Result<(String, BTreeSet<String>)> {
    let proxy = zbus::Proxy::new(connection, NAME, PATH, NAME).await?;
    let active: String = proxy.get_property("ActiveProfile").await?;
    let profiles: Vec<(String, String, String, String, bool)> =
        proxy.call("ListProfiles", &()).await?;
    let guests: Vec<(String, String, u32)> = proxy.call("ListGuests", &()).await?;
    let ids = profiles
        .into_iter()
        .map(|p| p.0)
        .chain(guests.into_iter().map(|g| g.0))
        .collect();
    Ok((active, ids))
}

/// Follows Profiles1 for as long as the bus is up: reads it now and again on its ActiveProfile
/// change, ProfilesChanged (profiles and guests made or removed) and its name coming back, and
/// hands each answer to `apply(active, ids)`. While Profiles1 does not answer it is asked every
/// `retry`; the caller never exits for it. `answering` is whether it answered last (a change is
/// logged as `who`, once each way). Returns when the bus closes.
pub async fn follow<F, Fut>(
    connection: &Connection,
    who: &str,
    retry: Duration,
    mut answering: bool,
    mut apply: F,
) where
    F: FnMut(String, BTreeSet<String>) -> Fut,
    Fut: Future<Output = ()>,
{
    let rule = |interface: &'static str, member: &'static str| {
        MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender(NAME)
            .and_then(|b| b.path(PATH))
            .and_then(|b| b.interface(interface))
            .and_then(|b| b.member(member))
            .map(|b| b.build())
    };
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, NAME))
        .map(|b| b.build());
    let (Ok(props), Ok(changed), Ok(owner)) = (
        rule("org.freedesktop.DBus.Properties", "PropertiesChanged"),
        rule(NAME, "ProfilesChanged"),
        owner,
    ) else {
        return eprintln!("{who}: cannot follow Profiles1");
    };
    let streams = (
        MessageStream::for_match_rule(props, connection, None).await,
        MessageStream::for_match_rule(changed, connection, None).await,
        MessageStream::for_match_rule(owner, connection, None).await,
    );
    let (Ok(a), Ok(b), Ok(c)) = streams else {
        return eprintln!("{who}: cannot follow Profiles1");
    };
    let mut stream = futures_lite::stream::or(futures_lite::stream::or(a, b), c);
    loop {
        // Read after the streams are set up, so no change is missed in between.
        match fetch(connection).await {
            Ok((active, ids)) => {
                if !answering {
                    eprintln!("{who}: Profiles1 answers again");
                }
                answering = true;
                apply(active, ids).await;
            }
            Err(err) => {
                if answering {
                    eprintln!(
                        "{who}: Profiles1 not readable, asking again every {} s: {err}",
                        retry.as_secs()
                    );
                }
                answering = false;
            }
        }
        let next = async { futures_lite::StreamExt::next(&mut stream).await.is_some() };
        let up = if answering {
            next.await
        } else {
            futures_lite::future::or(next, async {
                async_io::Timer::after(retry).await;
                true
            })
            .await
        };
        if !up {
            return eprintln!("{who}: the bus closed, Profiles1 is not followed");
        }
    }
}
