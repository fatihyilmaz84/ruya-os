//! The Steam items of each profile, into Library1 (ADR-045, RUY-1056): the adapter of the pure
//! planner in `profile_scan.rs`. Linux and system mode only (the reader runs in a profile's
//! manager).
//!
//! Triggers arrive on one channel: `dbus::watch_active_profile` sends every change of the
//! signed-in profile, `dbus::forward` every end of an instance, and `watch_library` here
//! Library1's new owners and its `ProfileScanWanted`. The actions are carried out in order:
//! `SetActiveProfile` is awaited before a scan starts. A scan runs on a thread of its own
//! (`spawner::profile_scan_command` through `bounded::run_capped`), so a slow reader holds up
//! nothing; its stdout goes unchanged to `PutProfileItems`, which checks it.

use std::time::Duration;

use async_channel::{Receiver, Sender};
use zbus::{Connection, MatchRule, MessageStream};

use crate::bounded::run_capped;
use crate::profile_scan::{Action, Planner, Trigger};
use crate::runner_choice::{ask_within, LIBRARY_IFACE, LIBRARY_NAME, LIBRARY_PATH};
use crate::spawner::profile_scan_command;

/// How long one reader may take: its unit's `RuntimeMaxSec` (20 s) and a little more.
const SCAN_LIMIT: Duration = Duration::from_secs(25);
/// The most output a reader may give: the 32 MiB a Library1 profile items document may have.
const MAX_DOCUMENT: usize = 32 * 1024 * 1024;
/// How long a call to Library1 may take (a put of a large document is decoded off its executor).
const CALL_LIMIT: Duration = Duration::from_secs(10);

/// A finished reader: the profile and its stdout (`None` when it failed, timed out or wrote
/// more than `MAX_DOCUMENT`; logged).
type Scanned = (String, Option<String>);

/// Runs forever: follows Library1 and carries out the planner's actions. `triggers` is the
/// receiving end of the channel whose sender went to the watchers.
pub async fn feed_library(
    connection: Connection,
    triggers: Receiver<Trigger>,
    own: Sender<Trigger>,
) {
    futures_lite::future::zip(
        watch_library(connection.clone(), own),
        drive(connection, triggers),
    )
    .await;
}

enum Next {
    Trigger(Trigger),
    Scanned(Scanned),
}

async fn drive(connection: Connection, triggers: Receiver<Trigger>) {
    let mut planner = Planner::new();
    let (done_tx, done_rx) = async_channel::unbounded::<Scanned>();
    loop {
        let next = futures_lite::future::or(
            async { triggers.recv().await.ok().map(Next::Trigger) },
            async { done_rx.recv().await.ok().map(Next::Scanned) },
        )
        .await;
        let trigger = match next {
            Some(Next::Trigger(t)) => t,
            Some(Next::Scanned((profile, out))) => {
                if let Some(data) = out {
                    put(&connection, &profile, data).await;
                }
                Trigger::Done(profile)
            }
            None => return eprintln!("ruya-session: the Steam reader's triggers are gone"),
        };
        for action in planner.on(trigger) {
            match action {
                Action::SetActive(profile) => set_active(&connection, &profile).await,
                Action::Scan(profile) => start_scan(profile, done_tx.clone()),
            }
        }
    }
}

/// `Library1.SetActiveProfile(profile)`; a failure is logged (a Library1 that comes up later gets
/// it again with its new owner).
async fn set_active(connection: &Connection, profile: &str) {
    let call = async {
        connection
            .call_method(
                Some(LIBRARY_NAME),
                LIBRARY_PATH,
                Some(LIBRARY_IFACE),
                "SetActiveProfile",
                &(profile,),
            )
            .await?
            .body()
            .deserialize::<String>()
    };
    match ask_within(CALL_LIMIT, call).await {
        Ok(status) if status == "ok" => {}
        Ok(status) => {
            eprintln!("ruya-session: Library1 SetActiveProfile({profile:?}) answered {status:?}")
        }
        Err(why) => eprintln!("ruya-session: Library1 SetActiveProfile({profile:?}): {why}"),
    }
}

/// `Library1.PutProfileItems(profile, data)`, the reader's output unchanged.
async fn put(connection: &Connection, profile: &str, data: String) {
    let bytes = data.len();
    let call = async {
        connection
            .call_method(
                Some(LIBRARY_NAME),
                LIBRARY_PATH,
                Some(LIBRARY_IFACE),
                "PutProfileItems",
                &(profile, data.as_str()),
            )
            .await?
            .body()
            .deserialize::<String>()
    };
    match ask_within(CALL_LIMIT, call).await {
        Ok(status) if status == "ok" => {
            eprintln!("ruya-session: the Steam items of {profile} put ({bytes} bytes)")
        }
        Ok(status) => {
            eprintln!("ruya-session: Library1 PutProfileItems for {profile} answered {status:?}")
        }
        Err(why) => eprintln!("ruya-session: Library1 PutProfileItems for {profile}: {why}"),
    }
}

/// The reader of `profile` on a thread of its own; its result goes to `done`.
fn start_scan(profile: String, done: Sender<Scanned>) {
    std::thread::spawn(move || {
        let out = scan(&profile);
        let _ = done.send_blocking((profile, out));
    });
}

/// One reader run: its stdout when it exited 0, else `None` (logged).
fn scan(profile: &str) -> Option<String> {
    let args = match profile_scan_command(&ruya_ids::user_of(profile)) {
        Ok(args) => args,
        Err(err) => {
            eprintln!("ruya-session: no Steam reader for {profile}: {err}");
            return None;
        }
    };
    let started = std::time::Instant::now();
    let ran = run_capped(&args, SCAN_LIMIT, MAX_DOCUMENT)?;
    if ran.code != Some(0) {
        eprintln!(
            "ruya-session: the Steam reader of {profile} failed ({:?})",
            ran.code
        );
        return None;
    }
    eprintln!(
        "ruya-session: the Steam reader of {profile} took {} ms",
        started.elapsed().as_millis()
    );
    Some(ran.out)
}

/// Library1's new owners (`NameOwnerChanged`) and its `ProfileScanWanted`, as triggers.
async fn watch_library(connection: Connection, triggers: Sender<Trigger>) {
    let owner = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|b| b.member("NameOwnerChanged"))
        .and_then(|b| b.arg(0, LIBRARY_NAME))
        .map(|b| b.build());
    let wanted = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(LIBRARY_NAME)
        .and_then(|b| b.path(LIBRARY_PATH))
        .and_then(|b| b.interface(LIBRARY_IFACE))
        .and_then(|b| b.member("ProfileScanWanted"))
        .map(|b| b.build());
    let (Ok(owner), Ok(wanted)) = (owner, wanted) else {
        return eprintln!("ruya-session: cannot follow Library1");
    };
    let (owner, wanted) = match (
        MessageStream::for_match_rule(owner, &connection, None).await,
        MessageStream::for_match_rule(wanted, &connection, None).await,
    ) {
        (Ok(a), Ok(b)) => (a, b),
        (Err(err), _) | (_, Err(err)) => {
            return eprintln!("ruya-session: cannot follow Library1: {err}");
        }
    };
    let owners = futures_lite::StreamExt::filter_map(owner, |msg| {
        let (_, _, new): (String, String, String) = msg.ok()?.body().deserialize().ok()?;
        Some(Trigger::LibraryOwner(new))
    });
    let wants = futures_lite::StreamExt::filter_map(wanted, |msg| {
        let profile: String = msg.ok()?.body().deserialize().ok()?;
        Some(Trigger::Wanted(profile))
    });
    let mut stream = futures_lite::stream::or(owners, wants);
    while let Some(trigger) = futures_lite::StreamExt::next(&mut stream).await {
        if triggers.send(trigger).await.is_err() {
            return;
        }
    }
    eprintln!("ruya-session: the bus closed, Library1 is not followed");
}
