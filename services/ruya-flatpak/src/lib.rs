//! Flatpak as the services speak it: the grammar of an app id and the argument lists of the
//! `flatpak` commands more than one service runs (RUY-923, 03 §4.4). Pure: no I/O and no D-Bus;
//! running a command stays with each service (`ruya-store`'s `flatpak_cli.rs`, `ruya-play`'s
//! `Runner`). A rule two services need about Flatpak's own formats lives here, not in both.

pub mod oars;

/// A Flatpak application id: reverse-DNS, ASCII letters, digits, `_` and `-`, at least two dots,
/// no empty element, none starting with a digit, at most 255 characters (Flatpak's own limit).
/// Everything that reaches the `flatpak` command line has passed this.
pub fn valid_app_id(id: &str) -> bool {
    id.len() <= 255
        && !id.starts_with('-')
        && id.split('.').count() >= 3
        && id.split('.').all(|part| {
            !part.is_empty()
                && !part.starts_with(|c: char| c.is_ascii_digit())
                && part
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        })
}

/// `flatpak override` without `--reset` or `--show`: the arguments around the withdraw arguments
/// (the arguments after `flatpak`).
pub fn override_command(id: &str, args: &[String]) -> Vec<String> {
    let mut out = vec!["override".to_owned(), "--system".to_owned()];
    out.extend(args.iter().cloned());
    out.push(id.to_owned());
    out
}

/// `flatpak override --system --reset <id>`: removes the app's override, whoever wrote it. Every
/// uninstall runs it (`ruya-store`'s `Store::drop_override`, `ruya-play`'s `Commit::uninstall`),
/// so no withdrawal outlives its app.
pub fn reset_command(id: &str) -> Vec<String> {
    ["override", "--system", "--reset", id]
        .map(str::to_owned)
        .to_vec()
}

/// `flatpak override --system --show <id>`: the override keyfile, empty without one.
pub fn show_command(id: &str) -> Vec<String> {
    ["override", "--system", "--show", id]
        .map(str::to_owned)
        .to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn app_ids() {
        assert!(valid_app_id("org.example.Racer"));
        assert!(valid_app_id("org.ruyaos.Test_App-2"));
        assert!(valid_app_id("play.com.example.mini"));
        for bad in [
            "",
            "Racer",
            "org.example",
            "-org.example.Racer",
            "org..Racer",
            "org.1example.Racer",
            "org.example.Racer --user",
            "org.example.Rac/er",
            "org.example.Racer\n",
        ] {
            assert!(!valid_app_id(bad), "{bad:?}");
        }
        assert!(valid_app_id(&format!("org.a.{}", "x".repeat(249))));
        assert!(!valid_app_id(&format!("org.a.{}", "x".repeat(250))));
    }

    #[test]
    fn override_command_wraps_the_arguments() {
        assert_eq!(
            override_command("org.example.Racer", &args(&["--unshare=network"])),
            args(&[
                "override",
                "--system",
                "--unshare=network",
                "org.example.Racer"
            ])
        );
    }

    #[test]
    fn reset_command_is_fixed() {
        assert_eq!(
            reset_command("org.example.Racer"),
            args(&["override", "--system", "--reset", "org.example.Racer"])
        );
    }

    #[test]
    fn show_command_is_fixed() {
        assert_eq!(
            show_command("org.example.Racer"),
            args(&["override", "--system", "--show", "org.example.Racer"])
        );
    }
}
