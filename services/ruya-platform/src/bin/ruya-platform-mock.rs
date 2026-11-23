//! ruya-platform-mock: the Platform API on a developer's session bus (RUY-158; never in the image).
//! It serves the service's own `org.ruyaos.Platform1` objects (Lifecycle, and Manage unchecked as
//! in `--session`) over the service's core, with who a caller is taken from a scenario file
//! (`ruya_platform::mock`), plus the control interface `org.ruyaos.Platform1Mock`. Linux only: it
//! reads the caller's pidfd and environment from `/proc`, and the bus must pass the caller's
//! pidfd (`ProcessFD` in `GetConnectionCredentials`: the dbus-daemon and dbus-broker of Fedora 44
//! do).
//!
//!     ruya-platform-mock --scenario <file> [--state <dir>]    serve (until killed)
//!     ruya-platform-mock wait [<seconds>]                      wait until a mock serves (default 10)
//!     ruya-platform-mock fire <event> [<value_ms>] [--app <name>]
//!     ruya-platform-mock switch-profile <profile-id>
//!     ruya-platform-mock fault <Register|SaveDone> [<status>]  no status: the real answer again
//!
//! `fire`, `switch-profile` and `fault` print the answer and exit 0 once the mock answered.

use std::error::Error;
use std::time::{Duration, Instant};

use ruya_platform::mock::{MOCK_BUS_NAME, MOCK_PATH};
use zbus::fdo::DBusProxy;
use zbus::names::BusName;
use zbus::Connection;

const MOCK_INTERFACE: &str = "org.ruyaos.Platform1Mock";
const USAGE: &str = "usage: ruya-platform-mock --scenario <file> [--state <dir>]
       ruya-platform-mock wait [<seconds>]
       ruya-platform-mock fire <background|resume|stopping> [<value_ms>] [--app <name>]
       ruya-platform-mock switch-profile <profile-id>
       ruya-platform-mock fault <Register|SaveDone> [<status>]";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("wait") => wait(&args[1..]),
        Some("fire") => fire(&args[1..]),
        Some("switch-profile") if args.len() == 2 => control("SwitchProfile", (args[1].as_str(),)),
        Some("fault") if (2..=3).contains(&args.len()) => control(
            "Fault",
            (args[1].as_str(), args.get(2).map_or("", String::as_str)),
        ),
        Some("--help") | Some("-h") => {
            println!("{USAGE}");
            Ok(())
        }
        Some(a) if a.starts_with("--") => serve::run(&args),
        _ => Err(USAGE.into()),
    };
    if let Err(err) = result {
        eprintln!("ruya-platform-mock: {err}");
        std::process::exit(1);
    }
}

/// Whether a mock serves on the session bus.
async fn mock_runs(conn: &Connection) -> Result<bool, Box<dyn Error>> {
    let name = BusName::try_from(MOCK_BUS_NAME)?;
    Ok(DBusProxy::new(conn).await?.name_has_owner(name).await?)
}

fn not_running() -> Box<dyn Error> {
    format!(
        "no Platform mock on the session bus ({MOCK_BUS_NAME} has no owner): start \
         `ruya-platform-mock --scenario <file>` first"
    )
    .into()
}

fn wait(args: &[String]) -> Result<(), Box<dyn Error>> {
    let secs: u64 = match args {
        [] => 10,
        [s] => s.parse().map_err(|_| USAGE)?,
        _ => return Err(USAGE.into()),
    };
    futures_lite::future::block_on(async {
        let conn = Connection::session().await?;
        let until = Instant::now() + Duration::from_secs(secs);
        while !mock_runs(&conn).await? {
            if Instant::now() >= until {
                return Err(format!("{MOCK_BUS_NAME} did not appear within {secs} s").into());
            }
            async_io::Timer::after(Duration::from_millis(50)).await;
        }
        Ok(())
    })
}

fn fire(args: &[String]) -> Result<(), Box<dyn Error>> {
    let mut app = String::new();
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--app" {
            app = it.next().ok_or(USAGE)?.clone();
        } else {
            rest.push(a.as_str());
        }
    }
    let (event, value_ms) = match rest.as_slice() {
        [event] => (*event, 0),
        [event, ms] => (*event, ms.parse::<u64>().map_err(|_| USAGE)?),
        _ => return Err(USAGE.into()),
    };
    control("Fire", (app.as_str(), event, value_ms))
}

/// Calls `member` of the control interface and prints its status.
fn control<B>(member: &str, body: B) -> Result<(), Box<dyn Error>>
where
    B: serde::Serialize + zbus::zvariant::DynamicType,
{
    futures_lite::future::block_on(async {
        let conn = Connection::session().await?;
        if !mock_runs(&conn).await? {
            return Err(not_running());
        }
        let reply = conn
            .call_method(
                Some(MOCK_BUS_NAME),
                MOCK_PATH,
                Some(MOCK_INTERFACE),
                member,
                &body,
            )
            .await?;
        let status: String = reply.body().deserialize()?;
        println!("{status}");
        Ok(())
    })
}

#[cfg(target_os = "linux")]
mod serve {
    use std::error::Error;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    use ruya_platform::dbus::{watch_names, BUS_NAME, OBJECT_PATH};
    use ruya_platform::mock::{self, LinuxProcesses, Scenario, APP_ENV, MOCK_BUS_NAME, MOCK_PATH};
    use ruya_platform::store::Store;
    use zbus::fdo::DBusProxy;
    use zbus::names::BusName;

    pub fn run(args: &[String]) -> Result<(), Box<dyn Error>> {
        let (mut scenario_file, mut state) = (None, None);
        let mut it = args.iter();
        while let Some(a) = it.next() {
            match a.as_str() {
                "--scenario" => scenario_file = it.next().map(PathBuf::from),
                "--state" => state = it.next().map(PathBuf::from),
                _ => return Err(super::USAGE.into()),
            }
        }
        let scenario_file = scenario_file.ok_or(super::USAGE)?;
        let text = std::fs::read_to_string(&scenario_file)
            .map_err(|e| format!("{}: {e}", scenario_file.display()))?;
        let scenario = Arc::new(
            Scenario::parse(&text).map_err(|e| format!("{}: {e}", scenario_file.display()))?,
        );
        // Each run starts with no choices: every capability has its default. A folder the mock
        // made itself is removed when it ends (the bus closed, SIGTERM, SIGINT or an error); one
        // given with --state is the caller's.
        let own = state.is_none();
        let state = state.unwrap_or_else(|| {
            std::env::temp_dir().join(format!("ruya-platform-mock-{}", std::process::id()))
        });
        if own {
            remove_on_signal(state.clone());
        }
        let result = serve(scenario, &state);
        if own {
            let _ = std::fs::remove_dir_all(&state);
        }
        result
    }

    /// SIGTERM and SIGINT are blocked in every thread (this runs before zbus starts its threads)
    /// and taken by one thread of their own, which removes `dir` and ends the process.
    fn remove_on_signal(dir: PathBuf) {
        // SAFETY: plain libc calls on a sigset_t this function owns; sigwait only reads it.
        let set = unsafe {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGTERM);
            libc::sigaddset(&mut set, libc::SIGINT);
            libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
            set
        };
        std::thread::spawn(move || {
            let mut signal = 0;
            // SAFETY: as above; `signal` is a valid out pointer.
            unsafe { libc::sigwait(&set, &mut signal) };
            let _ = std::fs::remove_dir_all(&dir);
            std::process::exit(0);
        });
    }

    fn serve(scenario: Arc<Scenario>, state: &std::path::Path) -> Result<(), Box<dyn Error>> {
        let store = Store::open(state)?;
        let core = mock::core(scenario.clone(), Box::new(LinuxProcesses), store)?;
        let objects = mock::Objects::new(core.clone(), scenario.clone());

        futures_lite::future::block_on(async {
            let connection = zbus::connection::Builder::session()?
                .method_timeout(Duration::from_secs(10))
                .serve_at(OBJECT_PATH, objects.lifecycle)?
                .serve_at(OBJECT_PATH, objects.manage)?
                .serve_at(MOCK_PATH, objects.control)?
                .build()
                .await?;
            // The recipe needs the caller's pidfd: a bus that gives none makes every caller
            // not-an-app, so say so now instead.
            let bus = DBusProxy::new(&connection).await?;
            let me = connection.unique_name().ok_or("no unique name")?.clone();
            let creds = bus
                .get_connection_credentials(BusName::try_from(me.as_str())?)
                .await?;
            if creds.process_fd().is_none() {
                return Err(
                    "this bus gives no ProcessFD in GetConnectionCredentials, so no caller \
                            could be identified: use a newer dbus-daemon or dbus-broker (Fedora \
                            44's have it)"
                        .into(),
                );
            }
            connection
                .request_name(BUS_NAME)
                .await
                .map_err(|e| format!("{BUS_NAME} is taken on this bus: {e}"))?;
            connection.request_name(MOCK_BUS_NAME).await?;
            let apps: Vec<String> = scenario
                .apps
                .iter()
                .map(|(name, app)| {
                    let default = scenario.default_app.as_deref() == Some(name.as_str());
                    format!(
                        "{name} = {} {}{}",
                        app.app_id,
                        app.instance,
                        if default { " (default)" } else { "" }
                    )
                })
                .collect();
            eprintln!(
                "ruya-platform-mock: serving {BUS_NAME} and {MOCK_BUS_NAME} on the session bus; \
                 every caller is profile {} (active {}); apps by {APP_ENV}: {}; permissions in {}",
                scenario.profile,
                scenario.active(),
                apps.join(", "),
                state.display()
            );
            watch_names(connection.clone(), core).await;
            Ok::<(), Box<dyn Error>>(())
        })
    }
}

#[cfg(not(target_os = "linux"))]
mod serve {
    pub fn run(_args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
        Err(
            "the mock serves on Linux only (it reads the caller's pidfd and environment from \
             /proc); its control commands work anywhere"
                .into(),
        )
    }
}
