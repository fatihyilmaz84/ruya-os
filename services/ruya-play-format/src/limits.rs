//! Every limit and closed vocabulary of the format, in one place (05 §4, §9.3 rule 6).
//!
//! `api/play/play.schema.json` repeats the ones a schema can express; `tests/schema.rs` fails when
//! the two disagree. Each limit has a boundary test in `tests/limits.rs`.

/// The newest `format` major this crate understands.
pub const SUPPORTED_FORMAT: u64 = 1;

/// Largest `play.json`, in bytes (1 MiB).
pub const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
/// Deepest nesting of arrays and objects in `play.json` (the top-level object is depth 1).
pub const MAX_JSON_DEPTH: usize = 12;
/// Largest `play.files`, in bytes (64 MiB).
pub const MAX_TABLE_BYTES: u64 = 64 * 1024 * 1024;
/// Most entries in `play.files`.
pub const MAX_TABLE_ENTRIES: usize = 200_000;
/// Longest package path, in bytes.
pub const MAX_PATH_BYTES: usize = 1024;
/// Longest path component, in bytes.
pub const MAX_COMPONENT_BYTES: usize = 255;
/// Most links a chain of links may pass through before it reaches a file or directory.
pub const MAX_LINK_HOPS: usize = 8;
/// Most entries in a zip: the table's entries plus room for the directory entries zip tools add.
pub const MAX_ZIP_ENTRIES: usize = 220_000;
/// An entry at or below this uncompressed size is exempt from the expansion limit (1 MiB).
pub const EXPANSION_FREE_BYTES: u64 = 1024 * 1024;
/// An entry above [`EXPANSION_FREE_BYTES`] may expand at most this many times.
pub const MAX_EXPANSION_RATIO: u64 = 200;
/// Most problems one validation returns (the last one says the list was cut).
pub const MAX_PROBLEMS: usize = 100;

/// Most languages in a localized text, in `languages` and in a name map.
pub const MAX_LANGUAGES: usize = 30;
/// Longest language tag.
pub const MAX_LANGUAGE_TAG_BYTES: usize = 35;
/// Longest `name`, in characters.
pub const MAX_NAME_CHARS: usize = 60;
/// Longest `summary`, in characters.
pub const MAX_SUMMARY_CHARS: usize = 140;
/// Longest `description`, in characters.
pub const MAX_DESCRIPTION_CHARS: usize = 4000;
/// Longest `version`, in characters.
pub const MAX_VERSION_CHARS: usize = 32;
/// Longest developer or publisher name, in characters.
pub const MAX_CREDIT_NAME_CHARS: usize = 80;
/// Most `genres`.
pub const MAX_GENRES: usize = 4;
/// Most `tags`.
pub const MAX_TAGS: usize = 12;
/// Longest tag, in characters.
pub const MAX_TAG_CHARS: usize = 24;
/// Most `links`.
pub const MAX_LINKS: usize = 12;
/// Longest URL, in bytes.
pub const MAX_URL_BYTES: usize = 2048;
/// Most `art.screenshots`.
pub const MAX_SCREENSHOTS: usize = 20;
/// Longest screenshot caption, in characters.
pub const MAX_CAPTION_CHARS: usize = 100;
/// Longest permission reason, in characters.
pub const MAX_REASON_CHARS: usize = 120;
/// Longest `id`, in bytes.
pub const MAX_ID_BYTES: usize = 120;
/// Longest Flatpak id (`play.<id>`), in bytes.
pub const MAX_FLATPAK_ID_BYTES: usize = 255;
/// Fewest elements in an `id`.
pub const MIN_ID_ELEMENTS: usize = 3;
/// Most `components`.
pub const MAX_COMPONENTS: usize = 16;
/// Longest component id or setup step id, in bytes.
pub const MAX_LOCAL_ID_BYTES: usize = 32;
/// Longest version string of a component, in bytes.
pub const MAX_COMPONENT_VERSION_BYTES: usize = 32;
/// Most `run.env` variables.
pub const MAX_ENV_ENTRIES: usize = 64;
/// Longest `run.env` variable name, in bytes.
pub const MAX_ENV_NAME_BYTES: usize = 64;
/// Longest `run.env` value, in bytes.
pub const MAX_ENV_VALUE_BYTES: usize = 1024;
/// Most arguments in a command.
pub const MAX_COMMAND_ARGS: usize = 64;
/// Longest command argument, in bytes.
pub const MAX_ARG_BYTES: usize = 4096;
/// Most `run.setup` steps.
pub const MAX_SETUP_STEPS: usize = 16;
/// Most `run.discs`.
pub const MAX_DISCS: usize = 16;
/// Most paths in `data.saves` and in `data.cache`, each.
pub const MAX_DATA_PATHS: usize = 32;
/// Most `run.writable` folders (ADR-040).
pub const MAX_WRITABLE: usize = 16;
/// Most table bytes under all `run.writable` folders together, 2 GiB (ADR-040; an initial value).
pub const MAX_WRITABLE_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// Most players.
pub const MAX_PLAYERS: u64 = 64;
/// Most OARS content attributes.
pub const MAX_AGE_ATTRIBUTES: usize = 40;
/// Longest SPDX licence expression.
pub const MAX_LICENCE_BYTES: usize = 256;

/// Files at the package root that are not in `play.files`.
pub const ROOT_FILES: [&str; 4] = ["play.json", "play.files", "play.sig", "store.sig"];

/// `genres`, closed.
pub const GENRES: [&str; 21] = [
    "action",
    "adventure",
    "arcade",
    "platformer",
    "puzzle",
    "racing",
    "role-playing",
    "shooter",
    "simulation",
    "sports",
    "strategy",
    "fighting",
    "music",
    "party",
    "family",
    "sandbox",
    "horror",
    "visual-novel",
    "retro",
    "utility",
    "other",
];
/// `links[].kind`, closed.
pub const LINK_KINDS: [&str; 10] = [
    "homepage",
    "support",
    "manual",
    "source",
    "community",
    "store",
    "privacy",
    "changelog",
    "donate",
    "other",
];
/// `controller`, closed.
pub const CONTROLLER: [&str; 3] = ["full", "partial", "none"];
/// `players.modes`, closed.
pub const PLAYER_MODES: [&str; 3] = ["single", "local", "online"];
/// `age_rating.content` values (OARS 1.1), closed: the table `ruya-store` rates AppStream with too.
pub use ruya_flatpak::oars::OARS_VALUES;
/// `requirements.gpu_api`, closed.
pub const GPU_APIS: [&str; 2] = ["vulkan", "opengl"];
/// `run.runner`, closed.
pub const RUNNERS: [&str; 5] = ["native", "wine", "proton", "emulator", "engine"];
/// The `run.runner` values that run Windows programs: X11 (05 section 6.3) and the runtime's 32-bit
/// libraries mounted at [`I386_LIB_DIR`] (ADR-038).
pub const WINDOWS_RUNNERS: [&str; 2] = ["wine", "proton"];

/// Is `runner` one of [`WINDOWS_RUNNERS`]?
pub fn windows_runner(runner: &str) -> bool {
    WINDOWS_RUNNERS.contains(&runner)
}

/// Where the console mounts the runtime's 32-bit libraries (`org.freedesktop.Platform.Compat.i386`)
/// in the `/app` of a package of a Windows runner (ADR-038, RUY-900): such a package may have
/// nothing there (`run.lib_i386_reserved`).
pub const I386_LIB_DIR: &str = "lib/i386-linux-gnu";
/// `components[].type`, closed.
pub const COMPONENT_TYPES: [&str; 4] = ["wine", "proton", "emulator", "engine"];
/// `components[].source`, closed.
pub const COMPONENT_SOURCES: [&str; 5] = [
    "bundled",
    "system",
    "prefer-system",
    "prefer-bundled",
    "newest",
];
/// `run.launch_mode`, closed.
pub const LAUNCH_MODES: [&str; 3] = ["fullscreen", "gamescope", "default"];
/// `run.prefix.arch`, closed.
pub const PREFIX_ARCHES: [&str; 2] = ["win32", "win64"];
/// `permissions.input`, closed; the first is the default.
pub const INPUT_MODES: [&str; 3] = ["controllers+keyboard-mouse", "controllers", "all-devices"];
/// `permissions.removable_media`, closed; the first is the default.
pub const REMOVABLE_MEDIA: [&str; 3] = ["none", "read", "write"];
/// The boolean permission keys.
pub const BOOL_PERMISSIONS: [&str; 5] = ["network", "multiarch", "gamemode", "realtime", "devel"];
/// Every key `permissions` accepts. `microphone`, `camera` and `bluetooth` are not in it (05 §18
/// item 12): until the platform maps them, a package that asks is refused, not silently reduced.
pub const PERMISSION_KEYS: [&str; 8] = [
    "network",
    "input",
    "removable_media",
    "multiarch",
    "gamemode",
    "realtime",
    "devel",
    "reasons",
];
/// Every key `run` accepts.
pub const RUN_KEYS: [&str; 10] = [
    "runner",
    "component",
    "command",
    "cwd",
    "env",
    "launch_mode",
    "prefix",
    "setup",
    "discs",
    "writable",
];
/// Every key a `components[]` entry accepts.
pub const COMPONENT_KEYS: [&str; 7] = [
    "id",
    "type",
    "source",
    "min",
    "tested",
    "max_major",
    "bundled",
];
/// Every key `components[].bundled` accepts.
pub const BUNDLED_KEYS: [&str; 4] = ["path", "version", "licence", "source_url"];
/// Every key `run.prefix` accepts.
pub const PREFIX_KEYS: [&str; 3] = ["arch", "template", "epoch"];
/// Every key a `run.setup[]` step accepts.
pub const SETUP_KEYS: [&str; 3] = ["id", "command", "once"];
/// The newest `runner.json` `format` this crate understands (ADR-037).
pub const SUPPORTED_RUNNER_FORMAT: u64 = 1;
/// Largest `runner.json`, in bytes (64 KiB).
pub const MAX_RUNNER_JSON_BYTES: u64 = 64 * 1024;
/// Longest runner `family`, in bytes (`[a-z0-9][a-z0-9.-]{0,63}`).
pub const MAX_RUNNER_FAMILY_BYTES: usize = 64;
/// Every key `runner.json` accepts.
pub const RUNNER_KEYS: [&str; 9] = [
    "format",
    "family",
    "kind",
    "version",
    "arch",
    "entry",
    "capabilities",
    "licence",
    "source_url",
];
/// The keys `runner.json` must have (`entry` too for `wine` and `proton`).
pub const RUNNER_REQUIRED_KEYS: [&str; 5] = ["format", "family", "kind", "version", "arch"];
/// The one architecture a runner of format 1 runs on.
pub const RUNNER_ARCH: &str = "x86_64";
/// The `entry` keys of a `wine` runner.
pub const RUNNER_ENTRY_WINE: [&str; 2] = ["wine", "wineserver"];
/// The `entry` keys of a `proton` runner.
pub const RUNNER_ENTRY_PROTON: [&str; 1] = ["proton"];
/// The closed list of runner `capabilities` (informational in format 1).
pub const RUNNER_CAPABILITIES: [&str; 4] = ["multiarch", "dxvk", "vkd3d", "ntsync"];
/// The placeholders `run.command`, `run.cwd` and setup commands substitute (05 §6.3). Anything else
/// is literal text.
pub const PLACEHOLDERS: [&str; 5] = ["payload", "data", "config", "prefix", "disc"];
/// Names an app may not take unless the package is official (normalised: lower case, letters and
/// digits only). Any name containing `ruyaos` is refused as well.
pub const RESERVED_APP_NAMES: [&str; 6] =
    ["settings", "ruyaos", "store", "home", "guide", "update"];

/// `run.env` names the platform owns, matched exactly (05 §6.3, §18 item 21).
pub const ENV_DENY_EXACT: [&str; 15] = [
    "PATH",
    "HOME",
    "DISPLAY",
    "XAUTHORITY",
    "WINEPREFIX",
    "WINESERVER",
    "WINELOADER",
    "WINEDLLPATH",
    "WINEARCH",
    "TMPDIR",
    "GCONV_PATH",
    "LOCPATH",
    "NLSPATH",
    // The launcher sets the working folder (`PWD`); `UMU_ID` is a game id protonfixes would apply
    // fixes for, and a package has none (RUY-969). `SteamAppId` and `SteamGameId` need no entry:
    // their names are not `[A-Z][A-Z0-9_]*`, so `run.env` cannot carry them.
    "PWD",
    "UMU_ID",
];
/// `run.env` name prefixes the platform owns. This is a deny table, not an allow-list: native games
/// need variables of their own, and a package can do nothing in its own sandbox that it could not do
/// anyway; these are the ones that break what the launcher sets.
pub const ENV_DENY_PREFIX: [&str; 19] = [
    "LD_",
    "XDG_",
    "FLATPAK_",
    "DBUS_",
    "WAYLAND_",
    "PULSE_",
    "PIPEWIRE_",
    "SDL_",
    "STEAM_COMPAT_",
    "PRESSURE_VESSEL_",
    "VK_",
    "MESA_",
    "LIBGL_",
    "GST_",
    "QT_",
    "GTK_",
    "GDK_",
    "GIO_",
    "RUYA_",
];

/// True when an entry of `uncompressed` bytes stored in `compressed` bytes expands more than the
/// format allows (05 §4.3).
pub fn expansion_exceeds(uncompressed: u64, compressed: u64) -> bool {
    uncompressed > EXPANSION_FREE_BYTES
        && uncompressed > compressed.saturating_mul(MAX_EXPANSION_RATIO)
}
