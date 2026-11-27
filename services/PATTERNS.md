# services/ — reference (read the part your task needs)

The rules are in `services/CLAUDE.md`; this file is the catalogue they point to.

## Shared homes (look here before writing a helper)

A rule two crates need lives in one library crate, never copied into both. Inside a service, one module owns each rule (`ruya-play`'s `reconcile::open_ours` is the one origin check). A new rule a second crate will need goes into the library crate in the same branch, and gets a row here.

| Crate | What lives there | Users |
|---|---|---|
| `ruya-play-format` | The `.play` format: manifest, file table, paths, limits, problem codes, `runner.json` and the runner hash (`runner.rs`), `sha256_of` / `sha256_hex` / `hex` / `is_lower_hex` | `ruya-play`, `ruya-play-launch` |
| `ruya-play-art` | Art and video vetting, the art roles | `ruya-play` |
| `ruya-play-trust` | Signatures, keys, tiers, the trust record | `ruya-play` |
| `ruya-flatpak` | Pure: Flatpak's app-id grammar; the argument lists of the `flatpak` commands more than one service runs (`override`, `--reset`, `--show`; running them stays with each service); the OARS severity table and its age label (`oars`, RUY-914); the scope unit names and the cgroup file (`scope`: `unit_escape`, `is_app_scope`, the exact `instance_scope`, `parse_cgroup`, `runs_in_scope`, RUY-1098) | `ruya-store` (AppStream ratings), `ruya-play` (a manifest), `ruya-play-format` (validation); `ruya-session` (its apps' scopes), `ruya-platform` (a caller's identity) |
| `ruya-ids` | Pure, no dependencies (RUY-1008): the profile-id rule `valid_profile_id` (`[A-Za-z0-9_-]`, 1 to 32 bytes); the profile user name `user_of` / `profile_of_user` (`p3` <-> `ruya-p3`); the Library1 item id `parse_item` / `flatpak_item` (`flatpak:<id>` or `steam:<digits>`, RUY-1051). Flatpak app ids stay in `ruya-flatpak`; a later shared id goes here | the services that share those ids |
| `ruya-calendar` | Pure, no dependencies (RUY-29): `days_from_civil`, `civil_from_days`, `day_of(unix, utc_offset)`, `format_day` / `parse_day` (`YYYY-MM-DD`), `digits` for a date or time field | `ruya-update` (download ledger), `ruya-play-trust` (RFC 3339 times), `ruya-session` (usage days) |
| `ruya-jobs` | The ADR-026 job helpers (RUY-29): the smoothed `rate::Rate` of `rate_bps`, the per-day `ledger::Ledger` of `GetDownloadStats` (file path and kept days are the caller's) | `ruya-update`; Store1 next (RUY-28) |
| `ruya-keyfile` | The keyfile reader, a GKeyFile subset: groups, `key=value`, comments, a size cap, duplicates refused (RUY-1050) | `ruya-session` (the image's app table), `x11::context_sockets`; the other Flatpak keyfile parsers move onto it (RUY-926) |
| `ruya-contract-test` | The served-interface check and `parse_records` (`CLAUDE.md`, Rules) | every service's `tests/contract.rs` |
| `ruya-users` | The user database (`getpwnam_r` / `getpwuid_r` / `getgrgid_r`: `passwd_of`, `lookup_uid`, `uid_of`, `name_of`, `uid_in_use`, `gid_in_use`; RUY-1264) and the root-or-shell caller rule (`SHELL_USER`, `root_or_shell`), RUY-1098 | `ruya-session`, `ruya-notifications`, `ruya-platform`, `ruya-profiles`, `ruya-accounts` |
| `ruya-accounts` | The accounts helper's lib (ADR-049, RUY-1264): the one-line request grammar and reply (`wire`), the profile users' `useradd` arguments, guest uid range and passwd markers (`account`); the helper binary runs the commands | `ruya-profiles` (the client), the helper |
| `ruya-profiles-client` | Reading and following Profiles1 (`fetch`, `follow`: the active profile, profiles and guests, retried while it is away; what a service does with the answer stays its own), RUY-1098 | `ruya-notifications`, `ruya-platform` |
| `ruya-fs` | File access below a folder someone else controls (a profile's home, an app's data), never through a link (RUY-911): a `Dir` handle walked with `openat` per component; read with a cap, atomic write, 0700 folders, remove, copy (reflink first) and rename a tree, `set_mode`, `read_link`; `kind` and `entries` (names and kinds, a link reported as a link); `open_file(path)` for a caller with only a path | `ruya-session`, `ruya-library` (Steam's files), `ruya-play-launch`, `ruya-play-art`, `ruya-devices` |
| `ruya-vdf` | Valve's text KeyValues (`config.vdf`, `libraryfolders.vdf`, `appmanifest_*.acf`, `compatibilitytool.vdf`), RUY-960: the one Steam VDF reader and writer, text in and out; ordered, repeated keys kept, case-insensitive lookups, `//` comments and unquoted tokens read (file access stays `ruya-fs`'s) | `ruya-session`, `ruya-library` |
