//! The "Console" group: the system, its image, the kernel, the firmware and the machine.

use crate::source::Source;
use crate::value::Info;
use crate::{is_placeholder, tidy};

const SECURE_BOOT_VAR: &str =
    "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c";

/// The value of `KEY=value` in an os-release file, without quotes.
pub fn os_release_value(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once('=')?;
        if k.trim() != key {
            return None;
        }
        let v = v.trim().trim_matches('"').trim_matches('\'');
        (!v.is_empty()).then(|| v.to_owned())
    })
}

/// Seconds since boot from `/proc/uptime` ("12345.67 98765.43").
pub fn parse_uptime(text: &str) -> Option<u64> {
    let first = text.split_whitespace().next()?;
    let secs: f64 = first.parse().ok()?;
    (secs.is_finite() && secs >= 0.0).then_some(secs as u64)
}

/// "YYYY-MM" of a time in seconds since 1970 (UTC; a month is all this is used for).
pub fn year_month(seconds: u64) -> String {
    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days.div_euclid(146_097);
    let doe = days.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}")
}

/// The deployment the kernel was booted from: the commit of `ostree=/ostree/boot.1/<stateroot>/<commit>/<n>`
/// in the kernel command line, shortened to 12 characters.
pub fn parse_deployment(cmdline: &str) -> Option<String> {
    let value = cmdline
        .split_whitespace()
        .find_map(|w| w.strip_prefix("ostree="))?;
    let parts: Vec<&str> = value.split('/').filter(|p| !p.is_empty()).collect();
    let commit = parts.get(parts.len().checked_sub(2)?)?;
    let hex = commit.chars().all(|c| c.is_ascii_hexdigit());
    (hex && commit.len() >= 12).then(|| commit[..12].to_owned())
}

/// The image reference and digest of the booted deployment from `bootc status --json`.
pub fn parse_bootc(json: &str) -> (Option<String>, Option<String>) {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(json) else {
        return (None, None);
    };
    let text = |pointer: &str| {
        v.pointer(pointer)
            .and_then(|x| x.as_str())
            .map(str::to_owned)
            .filter(|s| !s.is_empty())
    };
    (
        text("/status/booted/image/image/image"),
        text("/status/booted/image/imageDigest"),
    )
}

/// The machine's maker and model from the DMI fields.
pub fn machine(src: &dyn Source) -> (Option<String>, Option<String>) {
    let field = |name: &str| {
        src.read_trim(&format!("/sys/class/dmi/id/{name}"))
            .map(|s| tidy(&s))
            .filter(|s| !is_placeholder(s))
    };
    let vendor = field("sys_vendor").or_else(|| field("board_vendor"));
    // Lenovo keeps the product's name in product_version and a type code in product_name.
    let lenovo = vendor
        .as_deref()
        .is_some_and(|v| v.eq_ignore_ascii_case("lenovo"));
    let model = if lenovo {
        field("product_version").or_else(|| field("product_name"))
    } else {
        field("product_name")
    }
    .or_else(|| field("board_name"));
    (vendor, model)
}

/// Secure Boot from the EFI variable: its value is four attribute bytes and then 0 or 1.
/// `None` on a BIOS machine or when the variable cannot be read.
pub fn secure_boot(src: &dyn Source) -> Option<bool> {
    let bytes = src.read_bytes(SECURE_BOOT_VAR)?;
    (bytes.len() >= 5).then(|| bytes[4] == 1)
}

/// The group `console.*`, the part that does not change while the console runs.
pub fn collect_static(src: &dyn Source, info: &mut Info) {
    let release = src
        .read("/etc/os-release")
        .or_else(|| src.read("/usr/lib/os-release"))
        .unwrap_or_default();
    if let Some(name) = os_release_value(&release, "NAME") {
        info.text("console.name", name);
    }
    // The image writes its version to a file of its own; os-release is the fallback.
    let version = src
        .read_trim("/usr/lib/ruyaos/version")
        .or_else(|| os_release_value(&release, "VERSION_ID"));
    if let Some(version) = version {
        info.text("console.version", version);
    }
    if let Some(kernel) = src
        .read_trim("/proc/sys/kernel/osrelease")
        .or_else(|| src.run("uname", &["-r"]).map(|s| s.trim().to_owned()))
    {
        info.text("console.kernel", kernel);
    }
    if let Some(arch) = src
        .read_trim("/proc/sys/kernel/arch")
        .or_else(|| src.run("uname", &["-m"]).map(|s| s.trim().to_owned()))
    {
        info.text("console.arch", arch);
    }
    if let Some(deployment) = src.read("/proc/cmdline").and_then(|c| parse_deployment(&c)) {
        info.text("console.deployment", deployment);
    }
    // `bootc status` needs root on a real image: the service runs as the shell's user, so this is
    // often absent there (and then so are the image and its digest).
    if let Some(json) = src.run("bootc", &["status", "--json"]) {
        let (image, digest) = parse_bootc(&json);
        if let Some(image) = image {
            info.text("console.image", image);
        }
        if let Some(digest) = digest {
            info.text("console.image_digest", digest);
        }
    }
    if let Some(seconds) = src.modified("/etc/machine-id") {
        info.text("console.installed", year_month(seconds));
    }
    if src.exists("/sys/firmware/efi") {
        info.text("console.firmware", "uefi");
    } else if src.exists("/sys/firmware") {
        info.text("console.firmware", "bios");
    }
    if let Some(on) = secure_boot(src) {
        info.flag("console.secure_boot", on);
    }
    let (vendor, model) = machine(src);
    if let Some(vendor) = vendor {
        info.text("console.vendor", vendor);
    }
    if let Some(model) = model {
        info.text("console.model", model);
    }
}

/// The group `console.*`, the live part.
pub fn collect_live(src: &dyn Source, info: &mut Info) {
    if let Some(seconds) = src.read("/proc/uptime").and_then(|t| parse_uptime(&t)) {
        info.unsigned("console.uptime_s", seconds);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::FakeSource;

    #[test]
    fn os_release_values_lose_their_quotes() {
        let text = "NAME=\"RuyaOS\"\nVERSION_ID=44\nPRETTY_NAME='RuyaOS 0.0.50'\n";
        assert_eq!(os_release_value(text, "NAME").as_deref(), Some("RuyaOS"));
        assert_eq!(
            os_release_value(text, "PRETTY_NAME").as_deref(),
            Some("RuyaOS 0.0.50")
        );
        assert_eq!(os_release_value(text, "VARIANT"), None);
    }

    #[test]
    fn uptime_is_whole_seconds() {
        assert_eq!(parse_uptime("12345.67 98765.43\n"), Some(12345));
        assert_eq!(parse_uptime(""), None);
        assert_eq!(parse_uptime("x y"), None);
    }

    #[test]
    fn year_month_of_known_dates() {
        assert_eq!(year_month(0), "1970-01");
        assert_eq!(year_month(1_730_419_200), "2024-11"); // 2024-11-01 00:00 UTC
        assert_eq!(year_month(1_709_251_199), "2024-02"); // 2024-02-29 23:59:59 UTC
        assert_eq!(year_month(1_709_251_200), "2024-03");
    }

    #[test]
    fn deployment_commit_from_the_command_line() {
        let line = "BOOT_IMAGE=(hd0,gpt2)/boot/ostree/default-4d2a/vmlinuz root=UUID=1 ostree=/ostree/boot.1/default/0f3a9c1b2d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4/0 rw";
        assert_eq!(parse_deployment(line).as_deref(), Some("0f3a9c1b2d4e"));
        assert_eq!(parse_deployment("root=/dev/sda1 rw"), None);
        assert_eq!(
            parse_deployment("ostree=/ostree/boot.1/default/short/0"),
            None
        );
    }

    #[test]
    fn bootc_status_gives_image_and_digest() {
        let json = r#"{"status":{"booted":{"image":{"image":{"image":"ghcr.io/ruyaos/ruyaos:stable"},"imageDigest":"sha256:abc123"}}}}"#;
        let (image, digest) = parse_bootc(json);
        assert_eq!(image.as_deref(), Some("ghcr.io/ruyaos/ruyaos:stable"));
        assert_eq!(digest.as_deref(), Some("sha256:abc123"));
        assert_eq!(parse_bootc("not json"), (None, None));
        assert_eq!(parse_bootc("{}"), (None, None));
    }

    #[test]
    fn machine_skips_placeholders_and_knows_lenovo() {
        let board = FakeSource::new()
            .file("/sys/class/dmi/id/sys_vendor", "To Be Filled By O.E.M.\n")
            .file("/sys/class/dmi/id/board_vendor", "ASRock\n")
            .file("/sys/class/dmi/id/product_name", "To Be Filled By O.E.M.\n")
            .file("/sys/class/dmi/id/board_name", "B450M Pro4\n");
        assert_eq!(
            machine(&board),
            (Some("ASRock".into()), Some("B450M Pro4".into()))
        );
        let lenovo = FakeSource::new()
            .file("/sys/class/dmi/id/sys_vendor", "LENOVO\n")
            .file("/sys/class/dmi/id/product_name", "20XW0055GE\n")
            .file(
                "/sys/class/dmi/id/product_version",
                "ThinkPad X1 Carbon Gen 9\n",
            );
        assert_eq!(
            machine(&lenovo).1.as_deref(),
            Some("ThinkPad X1 Carbon Gen 9")
        );
        assert_eq!(machine(&FakeSource::new()), (None, None));
    }

    #[test]
    fn secure_boot_reads_the_fifth_byte() {
        let on = FakeSource::from_dump(&format!("== bytes {SECURE_BOOT_VAR}\n06 00 00 00 01\n"));
        let off = FakeSource::from_dump(&format!("== bytes {SECURE_BOOT_VAR}\n06 00 00 00 00\n"));
        assert_eq!(secure_boot(&on), Some(true));
        assert_eq!(secure_boot(&off), Some(false));
        assert_eq!(secure_boot(&FakeSource::new()), None);
    }

    #[test]
    fn a_bare_machine_has_only_what_it_says() {
        let mut info = Info::new();
        collect_static(&FakeSource::new(), &mut info);
        assert!(
            info.is_empty(),
            "nothing readable, nothing reported: {info:?}"
        );
        // /sys/firmware without efi in it is a BIOS machine.
        collect_static(&FakeSource::new().dir("/sys/firmware/acpi"), &mut info);
        assert_eq!(info.get_text("console.firmware"), Some("bios"));
        assert_eq!(info.len(), 1);
    }
}
