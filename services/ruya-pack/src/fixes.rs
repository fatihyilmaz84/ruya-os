//! The one table of "how to fix it" lines, one per error code (and per code group). The codes
//! are the crates' own (`ruya-play-format`, `ruya-play-art`, `ruya-play-trust`) plus the few
//! `ruya-pack` adds. [`catalogue`] lists every known code with its line, so the developer guide's
//! error catalogue (RUY-105) is generated from here and never written by hand.

/// Codes `ruya-pack` adds to the crates' own.
pub mod codes {
    /// A copyleft or any bundled component has no licence text under `licences/`.
    pub const LICENCE_TEXT_MISSING: &str = "licence.text_missing";
    /// A copyleft bundled component has no `source_url` and no source under `licences/`.
    pub const LICENCE_SOURCE_MISSING: &str = "licence.source_missing";
    /// A real symbolic link in the source folder.
    pub const BUILD_SYMLINK: &str = "build.symlink";
    /// A symbolic link that cannot become a package link (absolute or leaving the folder).
    pub const BUILD_SYMLINK_UNSUPPORTED: &str = "build.symlink_unsupported";
    /// `play.sig` or `store.sig` in the source folder was left out of the build.
    pub const BUILD_SIGNATURE_DROPPED: &str = "build.signature_dropped";
    /// The output would overwrite the source folder or a file inside it.
    pub const BUILD_OUTPUT_INSIDE: &str = "build.output_inside";
    /// A file or zip over 4 GiB cannot be copied to a FAT32 drive.
    pub const SIZE_FAT32: &str = "size.fat32";
    /// `init` found files already in the folder.
    pub const INIT_NOT_EMPTY: &str = "init.not_empty";
    /// The command line is wrong.
    pub const USAGE: &str = "usage.error";
    /// A file could not be read or written.
    pub const IO: &str = "io.error";
    /// The key file or `RUYA_PACK_KEY` is not a key.
    pub const KEY_INVALID: &str = "key.invalid";
    /// No key was given.
    pub const KEY_MISSING: &str = "key.missing";
    /// `--rotate-from` names the signing key itself.
    pub const KEY_SAME: &str = "key.same";
    /// A key file would be overwritten.
    pub const KEY_EXISTS: &str = "key.exists";
    /// A runner needed by the package is not in the list given on the command line.
    pub const RESOLVE_NOT_CHECKED: &str = "resolve.not_checked";

    /// Every code of this module.
    pub const ALL: &[&str] = &[
        LICENCE_TEXT_MISSING,
        LICENCE_SOURCE_MISSING,
        BUILD_SYMLINK,
        BUILD_SYMLINK_UNSUPPORTED,
        BUILD_SIGNATURE_DROPPED,
        BUILD_OUTPUT_INSIDE,
        SIZE_FAT32,
        INIT_NOT_EMPTY,
        USAGE,
        IO,
        KEY_INVALID,
        KEY_MISSING,
        KEY_EXISTS,
        KEY_SAME,
        RESOLVE_NOT_CHECKED,
    ];
}

/// What [`fix_for`] says for a code nobody wrote a line for.
pub const FALLBACK: &str = "See the developer guide's error catalogue for this code.";

/// Exact codes first, then groups (`group.`) as the fallback inside a family of codes.
const FIXES: &[(&str, &str)] = &[
    // pack's own
    ("licence.text_missing", "Add the licence text of the bundled component as a file under licences/ whose name or folder names the component or the licence (licences/wine-LGPL-2.1.txt)."),
    ("licence.source_missing", "Set bundled.source_url to where the source of the bundled code can be downloaded, or ship the source as a file under sources/."),
    ("build.symlink", "Remove the link, or build with --links-as-data to record a relative link inside the folder in play.files."),
    ("build.symlink_unsupported", "Make the link relative and keep its target inside the same top-level folder, or replace it with a copy of the file."),
    ("build.signature_dropped", "Run ruya-pack sign on the new package: a signature covers play.files, which the build just wrote."),
    ("build.output_inside", "Choose an output file outside the package folder with -o."),
    ("size.fat32", "Format the USB drive as exFAT: FAT32 cannot hold a file of 4 GiB or more."),
    ("init.not_empty", "Choose an empty or new folder, or pass --force to add the skeleton files that are missing."),
    ("usage.error", "Run ruya-pack --help for the commands and options."),
    ("io.error", "Check that the path exists, that you may read it, and that the disk is not full."),
    ("key.invalid", "Use a key file made by ruya-pack keygen (header ruyaos-play-key-v1), or RUYA_PACK_KEY holding its base64 line."),
    ("key.missing", "Pass --key <file> or set RUYA_PACK_KEY; make a key with ruya-pack keygen <name>."),
    ("key.same", "Rotate from the previous key: --rotate-from takes the old key file, --key the new one."),
    ("key.exists", "Choose another name, or pass --force to replace the key (the old key is gone for good)."),
    ("resolve.not_checked", "Pass --system-wine <version> (or --system-proton-ge, --system-runner family=version) to check the dry run."),
    ("resolve.no_system_runner", "Give the component a bundled copy and source prefer-system or newest, or accept that the installer fetches the runner."),
    ("resolve.system_too_old", "Lower min if the older runner works, or bundle a copy and use source prefer-system or newest."),
    ("resolve.system_too_new", "Raise max_major once you tested the newer runner, or bundle a copy so the fence has a fallback."),
    ("resolve.no_bundled", "Add the bundled block (path, version, licence) and the files under components/, or choose source system."),
    // format
    ("format.too_new", "Install a newer ruya-pack; this package uses a newer format than the tool knows."),
    ("package.no_manifest", "Add play.json at the root of the package (ruya-pack init writes a skeleton)."),
    ("package.no_table", "Run ruya-pack build to write play.files."),
    ("package.extra_file", "Run ruya-pack build again: play.files must list every file."),
    ("package.extra_dir", "Run ruya-pack build again: play.files must list every folder that is empty."),
    ("package.missing_file", "Restore the file or run ruya-pack build again to rewrite play.files."),
    ("package.missing_dir", "Restore the folder or run ruya-pack build again to rewrite play.files."),
    ("package.size_mismatch", "The file changed after play.files was written; run ruya-pack build again."),
    ("package.hash_mismatch", "The file changed after play.files was written; run ruya-pack build again."),
    ("package.kind_mismatch", "A file and a folder swapped places; run ruya-pack build again."),
    ("package.root_kind", "play.json, play.files, play.sig and store.sig must be regular files."),
    ("package.read_failed", "Check that you may read the file and that the disk is healthy."),
    ("entry.symlink", "Remove the link, or build with --links-as-data to record it in play.files as a package link."),
    ("entry.hardlink", "Replace the hard link with a separate copy of the file."),
    ("entry.device", "Remove the device file; a package holds only regular files and folders."),
    ("entry.special", "Remove the special file (FIFO, socket); a package holds only regular files and folders."),
    ("path.case_collision", "Rename one of the files: names must differ by more than letter case (exFAT and Wine ignore case)."),
    ("path.traversal", "Remove the .. part from the path; every path stays inside the package."),
    ("path.reserved_name", "Rename the file: names like CON, NUL or COM1 cannot exist on Windows drives."),
    ("path.not_nfc", "Rename the file with its characters in Unicode normal form C (NFC)."),
    ("path.trailing_dot_space", "Remove the trailing dot or space from the name."),
    ("path.invalid_utf8", "Rename the file so its name is valid UTF-8."),
    ("id.invalid", "Use a reverse-DNS id such as com.example.mygame: three or more parts, letters, digits, _ and -, no part starting with a digit."),
    ("id.reserved", "Choose an id of your own; org.ruyaos. and play. are for the Official tier."),
    ("id.flatpak_invalid", "Use - only in the last part of the id, and keep it under 255 bytes."),
    ("lang.missing_en", "Add an \"en\" text next to the other languages."),
    ("url.not_https", "Use an https:// address."),
    ("art.missing", "Add the file listed in play.json to the package, or remove the entry."),
    ("art.extension", "Use .png, .jpg, .jpeg or .webp for images and .webm or .mp4 for video."),
    ("art.too_small", "Replace the image with one at least as large as the slot needs (icon 512x512, hero 1920x1080, cover 600x900, screenshots 1280x720)."),
    ("art.aspect_ratio", "Crop the image to the slot's shape (icon 1:1, hero and screenshots 16:9, cover 2:3)."),
    ("art.animated", "Use a still image; animation belongs in the preview video."),
    ("art.svg", "Export the image as PNG, JPEG or WebP; SVG is not accepted."),
    ("art.corrupt", "Export the image again from your editor; the file cannot be decoded."),
    ("art.colour_profile", "Export the image as sRGB (or with an RGB ICC profile)."),
    ("art.format_unsupported", "Use PNG, JPEG or WebP."),
    ("art.magic_mismatch", "The file's contents do not match its extension; export it again in the format its name says."),
    ("art.no_screenshots", "Add a screenshot, or remove the empty screenshots list."),
    ("art.too_many_screenshots", "Keep at most 20 screenshots."),
    ("art.file_too_large", "Make the file smaller: icon and logo 2 MB, cover and screenshots 4 MB, hero 8 MB."),
    ("art.dimensions_too_large", "Scale the image below 16384 pixels each way and 100 megapixels."),
    ("video.container_not_allowed", "Use a WebM or MP4 container."),
    ("video.codec_not_allowed", "Encode with VP9 or AV1 (WebM) or H.264 (MP4) and a supported audio codec."),
    ("video.too_long", "Shorten the video."),
    ("video.resolution_too_large", "Scale the video down to 1080p."),
    ("video.bitrate_too_high", "Re-encode the video at a lower bitrate."),
    ("video.frame_rate_too_high", "Re-encode the video at 60 frames per second or less."),
    // trust
    ("sig.play_json_changed", "play.json changed after signing; run ruya-pack sign again."),
    ("sig.play_files_changed", "play.files changed after signing; run ruya-pack sign again."),
    ("sig.rotations_changed", "Run ruya-pack sign again; do not edit play.sig by hand."),
    ("sig.bad_signature", "Run ruya-pack sign again with your key; do not edit play.sig by hand."),
    ("sig.wrong_id", "Sign this package, not a copy of another package's play.sig."),
    ("sig.wrong_build", "Run ruya-pack sign again after changing build."),
    ("ceiling.refused", "Remove the high-risk permission, or sign the package with a developer key."),
    ("trust.needs_developer_mode", "Sign the package (ruya-pack sign), or turn on developer mode on the console."),
    // groups
    ("format.", "Fix play.json as described; the schema is in api/play/play.schema.json."),
    ("json.", "Remove the repeated key from the JSON."),
    ("run.", "Fix the run block of play.json (05 section 6.3)."),
    ("manifest.", "Fix play.json: it must be one UTF-8 JSON object of at most 1 MiB, nested at most 12 deep."),
    ("value.", "Use one of the values the message lists."),
    ("list.", "Shorten the list or remove the repeated entry."),
    ("id.", "Fix the package id."),
    ("name.", "Choose another name; system-like names are for the Official tier."),
    ("text.", "Write plain text: no markup, no links, no control or invisible characters."),
    ("lang.", "Use BCP-47 language tags such as en, tr or pt-BR, at most 30."),
    ("url.", "Use a plain https:// address."),
    ("requirements.", "Set requirements.arch to x86_64."),
    ("permissions.", "Use only the permission keys of 05 section 8; remove the unknown one."),
    ("component.", "Fix the components block of play.json (05 section 6.2)."),
    ("env.", "Remove or rename the environment variable; the console sets its own."),
    ("prefix.", "Fix run.prefix; the launcher creates dosdevices itself."),
    ("art.", "Fix the image as the message says."),
    ("data.", "Use a prefix:, data: or config: path inside the package's own data."),
    ("path.", "Rename the file or folder so its path follows 05 section 4.2."),
    ("entry.", "Remove the entry; a package holds only regular files and folders."),
    ("table.reserved_top_level", "Move the contents below another folder (for example payload/): .ref, launcher and share at the top of a package belong to the console."),
    ("table.", "Run ruya-pack build to write play.files again; do not edit it by hand."),
    ("link.", "Fix the link: relative target, inside the same top-level folder, at most 8 hops, no loop."),
    ("package.", "Run ruya-pack build to write play.files again."),
    ("problems.", "Fix the problems listed first, then run the command again."),
    ("zip.", "Build the zip with ruya-pack build; other zip tools may write what the console refuses."),
    ("folder.", "Check the folder: names must be UTF-8 and the folder must be readable and under the entry limit."),
    ("video.", "Fix the video as the message says (05 section 5)."),
    ("sig.", "Run ruya-pack sign again."),
    ("store_sig.", "Remove store.sig; only the store writes it."),
    ("rotation.", "Rotate with ruya-pack sign --rotate-from <old key file>, from the key the console last saw."),
    ("trust.", "Sign the package with your developer key."),
    ("revoked.", "This package, key or runner is on the revocation list; do not distribute it."),
    ("blocklist.", "The console's blocklist is not the tool's business; update the console."),
    ("state.", "The console's trust state is damaged; this is not a package problem."),
    ("resolve.", "Check the components block against the runners the console has."),
    ("licence.", "Fix the licence duty of the bundled component (05 section 6.2)."),
    ("build.", "Fix the source folder as the message says, then build again."),
    ("key.", "Check the key file or RUYA_PACK_KEY."),
    ("size.", "Reduce the size or choose exFAT for the drive."),
];

/// The one-line fix for `code`: the exact entry, else its group's, else [`FALLBACK`].
pub fn fix_for(code: &str) -> &'static str {
    if let Some((_, fix)) = FIXES.iter().find(|(c, _)| *c == code) {
        return fix;
    }
    let group = code.split_once('.').map(|(g, _)| format!("{g}."));
    group
        .and_then(|g| FIXES.iter().find(|(c, _)| *c == g).map(|(_, f)| *f))
        .unwrap_or(FALLBACK)
}

/// Codes of `ruya-play-art` (its crate has no list).
pub const ART_CODES: &[&str] = &[
    ruya_play_art::codes::NOT_A_FILE,
    ruya_play_art::codes::FILE_TOO_LARGE,
    ruya_play_art::codes::IO,
    ruya_play_art::codes::SVG,
    ruya_play_art::codes::MAGIC_MISMATCH,
    ruya_play_art::codes::FORMAT_UNSUPPORTED,
    ruya_play_art::codes::ANIMATED,
    ruya_play_art::codes::CORRUPT,
    ruya_play_art::codes::DIMENSIONS_TOO_LARGE,
    ruya_play_art::codes::TOO_SMALL,
    ruya_play_art::codes::ASPECT_RATIO,
    ruya_play_art::codes::COLOUR_PROFILE,
    ruya_play_art::codes::ICC_TOO_LARGE,
    ruya_play_art::codes::TOO_MANY_SCREENSHOTS,
    ruya_play_art::codes::VIDEO_NOT_A_FILE,
    ruya_play_art::codes::VIDEO_IO,
    ruya_play_art::codes::VIDEO_FILE_TOO_LARGE,
    ruya_play_art::codes::CONTAINER_NOT_ALLOWED,
    ruya_play_art::codes::HEADER_INVALID,
    ruya_play_art::codes::NO_VIDEO_TRACK,
    ruya_play_art::codes::CODEC_NOT_ALLOWED,
    ruya_play_art::codes::SAMPLE_ENTRIES,
    ruya_play_art::codes::CONTENT_ENCODING,
    ruya_play_art::codes::TRACK_NOT_ALLOWED,
    ruya_play_art::codes::AUDIO_NOT_ALLOWED,
    ruya_play_art::codes::NO_DURATION,
    ruya_play_art::codes::TOO_LONG,
    ruya_play_art::codes::RESOLUTION_TOO_LARGE,
    ruya_play_art::codes::FRAME_RATE_TOO_HIGH,
    ruya_play_art::codes::BITRATE_TOO_HIGH,
];

/// Codes of the dry run (`ruya_play_format::resolve::Unresolved::code`).
pub const RESOLVE_CODES: &[&str] = &[
    "resolve.no_system_runner",
    "resolve.system_too_old",
    "resolve.system_too_new",
    "resolve.no_bundled",
];

/// Every code a command can print, with its fix line, sorted by code: the error catalogue.
pub fn catalogue() -> Vec<(&'static str, &'static str)> {
    let mut all: Vec<&'static str> = Vec::new();
    all.extend(ruya_play_format::codes::ALL);
    all.extend(ART_CODES);
    all.extend(ruya_play_trust::codes::ALL);
    all.extend(RESOLVE_CODES);
    all.extend(codes::ALL);
    all.sort_unstable();
    all.dedup();
    all.into_iter().map(|c| (c, fix_for(c))).collect()
}
