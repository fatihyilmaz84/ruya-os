//! The `ruya-pack` program: arguments in, text or `--json` out, an exit code (0 ok, 1 problems,
//! 2 usage, 3 I/O). All the work is in the library.

use std::io::Write;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.iter().any(|a| a == "--json");
    let out = ruya_pack::run(&args, &ruya_pack::Context::from_process());
    let text = if json {
        let mut s = serde_json::to_string_pretty(&out.json).unwrap_or_default();
        s.push('\n');
        s
    } else {
        out.text.clone()
    };
    // A closed pipe (`| head`) must not turn into a panic.
    let _ = if json || out.exit < ruya_pack::EXIT_USAGE {
        std::io::stdout().write_all(text.as_bytes())
    } else {
        std::io::stderr().write_all(text.as_bytes())
    };
    std::process::exit(out.exit);
}
