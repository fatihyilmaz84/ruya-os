//! The player's runner choice for a `.play` game, on its way to the launcher (RUY-904, ADR-037).
//!
//! `ruya-library` keeps each profile's choice per game (Library1 `GetRunnerChoice`); this service
//! asks it at launch and puts `--runner=bundled` or `--runner=system` after the app id, which
//! `ruya-play-launch` reads as `ruya_play_launch::parse_args`. There is no second reader of
//! the library's files, and the names of the choices come from the launcher (`parse_choice`,
//! `runner_arg`): this module spells none of them.
//!
//! A launch never fails for the choice: the package's default (no flag) is used when Library1 is
//! absent, answers with an error status or does not answer in time, and the journal says so.
//!
//! The rules are pure ([`play_item`], [`choice_from_reply`], [`args_from_reply`]); the one D-Bus
//! call is [`ask_library`], over the service's own connection and bounded by [`ask_within`]. The
//! adapter makes it in `Session1.Launch` before the session lock is taken, so a slow Library1
//! holds up that one call only; the arguments then go through `Session::launch` to
//! `Spawner::start`.

use std::future::Future;
use std::time::Duration;

use zbus::Connection;

use ruya_play_format::resolve::Override;
use ruya_play_launch::{parse_choice, runner_arg};

/// Library1 on the system bus.
pub const LIBRARY_NAME: &str = "org.ruyaos.Library1";
pub const LIBRARY_PATH: &str = "/org/ruyaos/Library1";
pub const LIBRARY_IFACE: &str = "org.ruyaos.Library1";

/// How long a launch waits for Library1.
pub const ASK_LIMIT: Duration = Duration::from_secs(2);

/// The Library item id of the app, when it can be a `.play` app: Library1's ids are
/// `flatpak:<application id>` and a `.play` app's application id is `play.<id>`. Library1 has the
/// last word (a `play.*` app from another remote is `not_play` there); this only keeps the call
/// off every other launch.
pub fn play_item(app_id: &str) -> Option<String> {
    app_id
        .strip_prefix("play.")
        .filter(|id| !id.is_empty())
        .map(|_| format!("flatpak:{app_id}"))
}

/// The choice Library1 answered with, or the sentence for the journal.
pub fn choice_from_reply(status: &str, choice: &str) -> Result<Override, String> {
    if status != "ok" {
        return Err(format!("Library1 answered \"{status}\""));
    }
    parse_choice(choice).ok_or_else(|| format!("Library1 answered with the choice {choice:?}"))
}

/// The launch arguments Library1's reply (status and choice, or why there is none) adds: the
/// choice's flag, none for the package's default, and none for any failure, which is journaled.
pub fn args_from_reply(
    profile: &str,
    app_id: &str,
    reply: Result<(String, String), String>,
) -> Vec<String> {
    match reply.and_then(|(status, choice)| choice_from_reply(&status, &choice)) {
        Ok(choice) => runner_arg(choice).into_iter().collect(),
        Err(why) => {
            eprintln!(
                "ruya-session: {app_id} of {profile}: no runner choice ({why}); launching with the package default"
            );
            Vec::new()
        }
    }
}

/// `Library1.GetRunnerChoice(profile, id)` over `connection`: (status, choice).
pub async fn ask_library(
    connection: &Connection,
    profile: &str,
    item: &str,
) -> zbus::Result<(String, String)> {
    connection
        .call_method(
            Some(LIBRARY_NAME),
            LIBRARY_PATH,
            Some(LIBRARY_IFACE),
            "GetRunnerChoice",
            &(profile, item),
        )
        .await?
        .body()
        .deserialize()
}

/// The answer of `call`, or an error sentence when it fails or takes longer than `limit`.
pub async fn ask_within(
    limit: Duration,
    call: impl Future<Output = zbus::Result<(String, String)>>,
) -> Result<(String, String), String> {
    futures_lite::future::or(async { Some(call.await) }, async {
        async_io::Timer::after(limit).await;
        None
    })
    .await
    .ok_or_else(|| format!("no answer in {} s", limit.as_secs_f32()))?
    .map_err(|err| err.to_string())
}

/// The launch arguments the player's choice adds for `app_id` of `profile`: none for an app that
/// is not a `.play` game (`call` is not made), for the package's default, and for any failure of
/// `call(profile, item id)` or a wait longer than `limit`.
pub async fn runner_args<Fut>(
    limit: Duration,
    profile: &str,
    app_id: &str,
    call: impl FnOnce(String, String) -> Fut,
) -> Vec<String>
where
    Fut: Future<Output = zbus::Result<(String, String)>>,
{
    let Some(item) = play_item(app_id) else {
        return Vec::new();
    };
    let reply = ask_within(limit, call(profile.to_owned(), item)).await;
    args_from_reply(profile, app_id, reply)
}

/// The arguments for the launch of `app_id` as `profile`, Library1 asked over `connection`.
pub async fn runner_args_from_library(
    connection: &Connection,
    profile: &str,
    app_id: &str,
) -> Vec<String> {
    runner_args(ASK_LIMIT, profile, app_id, |profile, item| async move {
        ask_library(connection, &profile, &item).await
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_lite::future::block_on;
    use std::cell::Cell;

    fn answer(status: &str, choice: &str) -> Result<(String, String), String> {
        Ok((status.to_owned(), choice.to_owned()))
    }

    fn reply(status: &str, choice: &str) -> zbus::Result<(String, String)> {
        Ok((status.to_owned(), choice.to_owned()))
    }

    /// `runner_args` with a fake Library1 answering `result`.
    fn args(app_id: &str, result: zbus::Result<(String, String)>) -> Vec<String> {
        block_on(runner_args(ASK_LIMIT, "p1", app_id, |_, _| async {
            result
        }))
    }

    #[test]
    fn each_choice_gives_its_flag_and_the_default_none() {
        let flags = |choice: &str| args("play.hop", reply("ok", choice));
        assert_eq!(flags("package"), Vec::<String>::new());
        assert_eq!(flags("bundled"), ["--runner=bundled"]);
        assert_eq!(flags("system"), ["--runner=system"]);
    }

    #[test]
    fn library_is_asked_for_the_profile_and_the_library_item_id() {
        let asked = Cell::new(false);
        let got = block_on(runner_args(
            ASK_LIMIT,
            "p_2",
            "play.com.example.hop",
            |profile, item| {
                asked.set(true);
                assert_eq!(profile, "p_2");
                assert_eq!(item, "flatpak:play.com.example.hop");
                async { reply("ok", "system") }
            },
        ));
        assert!(asked.get());
        assert_eq!(got, ["--runner=system"]);
    }

    #[test]
    fn an_app_that_is_not_a_play_game_never_gets_a_flag_and_is_not_asked() {
        for app in [
            "org.ruyaos.Racer",
            "com.valvesoftware.Steam",
            "play",
            "play.",
            "xplay.hop",
        ] {
            let asked = Cell::new(false);
            let got = block_on(runner_args(ASK_LIMIT, "p1", app, |_, _| {
                asked.set(true);
                async { reply("ok", "system") }
            }));
            assert!(got.is_empty(), "{app}");
            assert!(!asked.get(), "Library1 asked for {app}");
        }
    }

    #[test]
    fn a_library_that_fails_gives_no_flag() {
        let unreachable = args("play.hop", Err(zbus::Error::Failure("no such name".into())));
        assert!(unreachable.is_empty());
        for (status, choice) in [
            ("not_play", ""),
            ("unknown", ""),
            ("invalid", ""),
            ("failed", ""),
            ("ok", "newest"),
            ("ok", ""),
            ("", "system"),
        ] {
            assert!(
                args("play.hop", reply(status, choice)).is_empty(),
                "{status:?} {choice:?}"
            );
        }
    }

    #[test]
    fn the_reply_is_read_with_the_launchers_names() {
        assert_eq!(choice_from_reply("ok", "bundled"), Ok(Override::Bundled));
        assert_eq!(choice_from_reply("ok", "system"), Ok(Override::System));
        assert_eq!(
            choice_from_reply("ok", "package"),
            Ok(Override::PackageDefault)
        );
        assert!(choice_from_reply("failed", "system").is_err());
        assert_eq!(
            args_from_reply("p1", "play.hop", answer("ok", "bundled")),
            ["--runner=bundled"]
        );
        assert!(args_from_reply("p1", "play.hop", Err("x".into())).is_empty());
    }

    #[test]
    fn the_flag_is_a_valid_launch_argument_after_the_app_id_in_both_modes() {
        use crate::spawner::{launch_command_in, DisplayMode};
        let env = [("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())];
        let app = "play.com.example.hop";
        let flags = args(app, reply("ok", "bundled"));
        for mode in [DisplayMode::Wayland, DisplayMode::X11] {
            let argv = launch_command_in("ruya-p1", app, &env, mode, &flags).expect("valid");
            assert_eq!(argv[argv.len() - 2..], [app, "--runner=bundled"]);
        }
    }

    #[test]
    fn a_fake_library_answers_inside_the_limit() {
        let got = block_on(ask_within(Duration::from_secs(5), async {
            reply("ok", "bundled")
        }));
        assert_eq!(got, answer("ok", "bundled"));
    }

    #[test]
    fn a_bus_error_is_a_sentence() {
        let got = block_on(ask_within(Duration::from_secs(5), async {
            Err(zbus::Error::Failure("ServiceUnknown".to_owned()))
        }));
        assert!(got.unwrap_err().contains("ServiceUnknown"));
    }

    /// Runs `future` on a thread and waits at most 10 s for it: a wait that is never given up
    /// fails the test instead of hanging it.
    fn finishes<T: Send + 'static>(future: impl Future<Output = T> + Send + 'static) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(block_on(future));
        });
        rx.recv_timeout(Duration::from_secs(10))
            .expect("the call was given up on at its limit")
    }

    #[test]
    fn a_library_that_never_answers_is_given_up_on_at_the_limit() {
        let got = finishes(ask_within(
            Duration::from_millis(100),
            std::future::pending::<zbus::Result<(String, String)>>(),
        ));
        assert!(got.unwrap_err().starts_with("no answer in"));
        // And the launch goes on with the default.
        let flags = finishes(runner_args(
            Duration::from_millis(50),
            "p1",
            "play.hop",
            |_, _| std::future::pending::<zbus::Result<(String, String)>>(),
        ));
        assert!(flags.is_empty());
    }
}
