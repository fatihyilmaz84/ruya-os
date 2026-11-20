//! `ruya-play-launch [--runner=package|bundled|system]`: prepare the game and `exec` it (ADR-037).
//! A failure is one sentence on stderr and exit status 1.

use std::process::ExitCode;

#[cfg(target_os = "linux")]
fn main() -> ExitCode {
    use ruya_play_launch::linux::{exec, LinuxOs};
    use ruya_play_launch::os::LaunchOs;
    use std::collections::BTreeMap;

    let mut os = LinuxOs;
    let args: Vec<String> = match std::env::args_os()
        .skip(1)
        .map(|a| a.into_string())
        .collect()
    {
        Ok(a) => a,
        Err(_) => {
            os.log("The launcher was started with an argument it does not know.");
            return ExitCode::FAILURE;
        }
    };
    let mut base_env = BTreeMap::new();
    for (k, v) in std::env::vars_os() {
        match (k.into_string(), v.into_string()) {
            (Ok(k), Ok(v)) => {
                base_env.insert(k, v);
            }
            (Ok(k), Err(_)) => os.log(&format!("{k} is not UTF-8 text; the game does not get it")),
            _ => os.log("a variable whose name is not UTF-8 text is left out"),
        }
    }
    match ruya_play_launch::prepare(&mut os, &args, &base_env) {
        Ok(cmd) => {
            let err = exec(&cmd);
            os.log(&format!("The game could not be started ({err})."));
        }
        Err(f) => os.log(&format!("{} [{}]", f.message, f.code)),
    }
    ExitCode::FAILURE
}

#[cfg(not(target_os = "linux"))]
fn main() -> ExitCode {
    eprintln!("ruya-play-launch: the launcher runs inside a game's sandbox on RuyaOS (Linux).");
    ExitCode::FAILURE
}
