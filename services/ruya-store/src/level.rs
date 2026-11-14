//! The console's API level (`RUYA_API_LEVEL` in os-release, RUY-156) and the AppStream minimum an
//! app asks for (`x-ruya-min-api-level`). Both are plain integers; anything else counts as 0
//! ("experimental, no promise"). The os-release rule is the one `ruya-sysinfo` uses (a shared
//! crate can come with ruya-platform).

use std::path::Path;

const KEY: &str = "RUYA_API_LEVEL";

/// An API level from text: a non-negative integer, otherwise 0.
pub fn parse_level(text: &str) -> u32 {
    text.trim().parse().unwrap_or(0)
}

/// `RUYA_API_LEVEL=n` from the text of an os-release file; missing or garbage gives 0.
pub fn level_from_os_release(text: &str) -> u32 {
    text.lines()
        .find_map(|line| {
            let (k, v) = line.split_once('=')?;
            (k.trim() == KEY).then(|| parse_level(v.trim().trim_matches('"').trim_matches('\'')))
        })
        .unwrap_or(0)
}

/// The level of this console: `/etc/os-release`, then `/usr/lib/os-release`; 0 when neither says.
pub fn api_level() -> u32 {
    for path in ["/etc/os-release", "/usr/lib/os-release"] {
        if let Some(text) = read(Path::new(path)) {
            if text
                .lines()
                .any(|l| l.split_once('=').is_some_and(|(k, _)| k.trim() == KEY))
            {
                return level_from_os_release(&text);
            }
        }
    }
    0
}

fn read(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_level_is_a_plain_integer() {
        assert_eq!(parse_level("7"), 7);
        assert_eq!(parse_level(" 12 "), 12);
        assert_eq!(parse_level("0"), 0);
        assert_eq!(parse_level(""), 0);
        assert_eq!(parse_level("-3"), 0);
        assert_eq!(parse_level("two"), 0);
        assert_eq!(parse_level("1.5"), 0);
        assert_eq!(parse_level("99999999999999"), 0);
    }

    #[test]
    fn os_release_gives_the_level() {
        let text = "NAME=\"RuyaOS\"\nRUYA_API_LEVEL=3\nVERSION_ID=1\n";
        assert_eq!(level_from_os_release(text), 3);
        assert_eq!(level_from_os_release("RUYA_API_LEVEL=\"4\"\n"), 4);
        assert_eq!(level_from_os_release("NAME=x\n"), 0, "missing");
        assert_eq!(level_from_os_release("RUYA_API_LEVEL=soon\n"), 0, "garbage");
        assert_eq!(
            level_from_os_release("XRUYA_API_LEVEL=5\n"),
            0,
            "another key"
        );
    }
}
