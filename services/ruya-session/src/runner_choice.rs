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
//! The rules are pure ([`play_item`], [`choice_from_reply`], [`runner_args`]); the one D-Bus call
//! is [`ask_library`], bounded by [`ask_within`].

use std::future::Future;
use std::time::Duration;

use ruya_play_format::resolve::Override;
use ruya_play_launch::{parse_choice, runner_arg};

/// Library1 on the system bus.
pub const LIBRARY_NAME: &str = "org.ruyaos.Library1";
pub const LIBRARY_PATH: &str = "/org/ruyaos/Library1";
pub const LIBRARY_IFACE: &str = "org.ruyaos.Library1";

/// How long a launch waits for Library1 (the call runs under the session lock).
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

/// The launch arguments the player's choice adds for `app_id` of the Unix user `user`: none for
/// an app that is not a `.play` game (`ask` is not called), for the package's default, and for
/// any failure of `ask(profile, item id)`, which is journaled. `ask` returns Library1's status
/// and choice.
pub fn runner_args(
    user: &str,
    app_id: &str,
    ask: impl FnOnce(&str, &str) -> Result<(String, String), String>,
) -> Vec<String> {
    let (Some(profile), Some(item)) = (user.strip_prefix("ruya-"), play_item(app_id)) else {
        return Vec::new();
    };
    let choice =
        ask(profile, &item).and_then(|(status, choice)| choice_from_reply(&status, &choice));
    match choice {
        Ok(choice) => runner_arg(choice).into_iter().collect(),
        Err(why) => {
            eprintln!(
                "ruya-session: {app_id} of {user}: no runner choice ({why}); launching with the package default"
            );
            Vec::new()
        }
    }
}

/// `Library1.GetRunnerChoice(profile, id)` on the system bus: (status, choice).
pub async fn ask_library(profile: &str, item: &str) -> zbus::Result<(String, String)> {
    let connection = zbus::connection::Builder::system()?.build().await?;
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
pub fn ask_within(
    limit: Duration,
    call: impl Future<Output = zbus::Result<(String, String)>>,
) -> Result<(String, String), String> {
    futures_lite::future::block_on(futures_lite::future::or(
        async { Some(call.await) },
        async {
            async_io::Timer::after(limit).await;
            None
        },
    ))
    .ok_or_else(|| format!("no answer in {} s", limit.as_secs_f32()))?
    .map_err(|err| err.to_string())
}

/// The arguments for the real launch of `app_id` as `user`: Library1 asked over the system bus.
pub fn runner_args_from_library(user: &str, app_id: &str) -> Vec<String> {
    runner_args(user, app_id, |profile, item| {
        ask_within(ASK_LIMIT, ask_library(profile, item))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn answer(status: &str, choice: &str) -> Result<(String, String), String> {
        Ok((status.to_owned(), choice.to_owned()))
    }

    #[test]
    fn each_choice_gives_its_flag_and_the_default_none() {
        let flags = |choice: &str| runner_args("ruya-p1", "play.hop", |_, _| answer("ok", choice));
        assert_eq!(flags("package"), Vec::<String>::new());
        assert_eq!(flags("bundled"), ["--runner=bundled"]);
        assert_eq!(flags("system"), ["--runner=system"]);
    }

    #[test]
    fn library_is_asked_for_the_profile_and_the_library_item_id() {
        let asked = Cell::new(false);
        let args = runner_args("ruya-p_2", "play.com.example.hop", |profile, item| {
            asked.set(true);
            assert_eq!((profile, item), ("p_2", "flatpak:play.com.example.hop"));
            answer("ok", "system")
        });
        assert!(asked.get());
        assert_eq!(args, ["--runner=system"]);
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
            let args = runner_args("ruya-p1", app, |_, _| {
                panic!("Library1 asked for {app}");
            });
            assert!(args.is_empty(), "{app}");
        }
        // Not a profile account: nothing to ask for.
        assert!(runner_args("root", "play.hop", |_, _| panic!("asked")).is_empty());
    }

    #[test]
    fn a_library_that_fails_gives_no_flag() {
        let unreachable = runner_args("ruya-p1", "play.hop", |_, _| Err("no such name".into()));
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
            let args = runner_args("ruya-p1", "play.hop", |_, _| answer(status, choice));
            assert!(args.is_empty(), "{status:?} {choice:?}");
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
    }

    #[test]
    fn the_flag_is_a_valid_launch_argument_after_the_app_id_in_both_modes() {
        use crate::spawner::{launch_command_in, DisplayMode};
        let env = [("WAYLAND_DISPLAY".to_owned(), "wayland-0".to_owned())];
        let flags = runner_args("ruya-p1", "play.com.example.hop", |_, _| {
            answer("ok", "bundled")
        });
        for mode in [DisplayMode::Wayland, DisplayMode::X11] {
            let argv = launch_command_in("ruya-p1", "play.com.example.hop", &env, mode, &flags)
                .expect("valid");
            assert_eq!(
                argv[argv.len() - 2..],
                ["play.com.example.hop", "--runner=bundled"]
            );
        }
    }

    #[test]
    fn a_fake_library_answers_inside_the_limit() {
        let got = ask_within(Duration::from_secs(5), async {
            Ok(("ok".to_owned(), "bundled".to_owned()))
        });
        assert_eq!(got, answer("ok", "bundled"));
    }

    #[test]
    fn a_bus_error_is_a_sentence() {
        let got = ask_within(Duration::from_secs(5), async {
            Err(zbus::Error::Failure("ServiceUnknown".to_owned()))
        });
        assert!(got.unwrap_err().contains("ServiceUnknown"));
    }

    #[test]
    fn a_library_that_never_answers_is_given_up_on_at_the_limit() {
        let started = std::time::Instant::now();
        let got = ask_within(
            Duration::from_millis(100),
            std::future::pending::<zbus::Result<(String, String)>>(),
        );
        assert!(got.unwrap_err().starts_with("no answer in"));
        assert!(started.elapsed() < Duration::from_secs(5));
        // And the launch goes on with the default.
        let args = runner_args("ruya-p1", "play.hop", |_, _| {
            ask_within(
                Duration::from_millis(50),
                std::future::pending::<zbus::Result<(String, String)>>(),
            )
        });
        assert!(args.is_empty());
    }
}
