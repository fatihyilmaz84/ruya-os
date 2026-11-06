# T-215 — Saves: back up and restore to USB, "Keep saves?" on uninstall, per-app data usage

Status: todo · Phase: 3 · Depends: — · Area: api, services, shell · Size: M · Owner: lead

## Goal
Players can protect and move their game progress: back up a profile's saves to a USB drive, restore them, keep saves when they uninstall a game, and see how much space each app's data takes. Implements the defaults of `docs/specs/03-services-and-apps.md` §4.5a (owner, 2026-11-06: "think of the file system: where do we save the save games, save states..."; the developer-facing rules are in `docs/developers/saves-and-data.md`).

## Read first
- Spec 03 **§4.5a** (the decided layout, backup format, lifecycle), §1 (profiles: 0700 homes, admin rules), §4.3 (`ruya-store`: `Uninstall(id, delete_data)`), the Storage text (T-196), `01-platform.md` §3 (mount policy: USB volumes mounted `nosuid,nodev,noexec`, read-write), `docs/developers/saves-and-data.md`
- `services/ruya-store` (root; `flatpak_cli.rs` already removes `~/.var/app/<id>` of every profile on uninstall), `services/ruya-profiles` (root; knows the profiles), `services/ruya-devices` (volumes), `api/dbus/org.ruyaos.Store1.xml`, `Devices1.Storage`, the shell Storage/Store panes and the app page uninstall flow, `shell/PATTERNS.md`

## Scope
1. **Which service:** the work needs root (profile homes are 0700). Put it in `ruya-store` (it already deletes app data as root and walks `/var/home`) unless reading the code shows a better home; record the decision. A new interface `org.ruyaos.Store1.Data` (or methods on `Store1`): `ListAppData(profile) -> aa{sv}` (app id, name, `data_bytes`, `config_bytes`, `cache_bytes`, `last_modified`), `Backup(profile, app_ids, volume_id) -> job`, `ListBackups(volume_id) -> aa{sv}` (parsed from the manifests on the drive), `Restore(admin?, backup_id, target_profile) -> job`, `ClearCache(profile, app_id)`, plus job progress/finished signals like the install jobs; statuses `ok`, `unknown-app`, `unknown-profile`, `unknown-volume`, `busy` (the app is running), `no-space`, `invalid-backup`, `needs-admin`, `failed`.
2. **Backup:** per app and profile, `data/` and `config/` (never `cache/`) into `RuyaOS-Backups/<profile name>/<app-id>/<UTC timestamp>.tar.zst` with a `manifest.json` (format version, app id, app version, profile name and id, created, per-part sizes, SHA-256 of the archive); written to a temporary name and renamed at the end; refused while the app runs (`busy`); never follows symlinks out of the app directory; file modes/ownership normalised; size and free-space check first; works to any mounted writable volume the Storage service lists (not the system volume). A progress signal per app.
3. **Restore:** for an installed app only, from a backup whose manifest and checksum verify; the current data moves aside to `data.before-restore/` (and config likewise) first and a failed restore puts it back; restoring into the profile it came from needs that profile's PIN if it has one; into another profile it needs an admin (`needs-admin`); extraction hardened (no absolute paths, no `..`, no links out, ownership of the target profile, mode 0700 dirs).
4. **Uninstall keeps saves by default:** the shell's uninstall flow asks "Keep saves?" (default Keep; Delete is explicit, admin-only to delete other profiles' data and says whose data goes); `Uninstall(delete_data=false)` leaves `~/.var/app/<id>` in place for every profile; reinstalling finds it. The Store reports "data left behind" for uninstalled apps so Settings -> Storage can list them with a Delete action.
5. **Per-app usage in Settings -> Storage:** a section "Apps and games" listing each app with app size + the profile's data size (from `ListAppData`), sorted by size, with "Clear cache" (always allowed, safe) and "Back up..." / "Delete data..." actions for admins and for the profile's own apps; the T-196 "Apps and games" total keeps working.
6. **Shell:** Settings -> Storage gets "Back up saves" (pick profile if admin, pick apps (default all), pick the drive, progress, result toast) and "Restore saves" (pick a drive, lists its backups by profile/app/date, choose target, PIN/admin flow, confirm); every step controller-first with focus asserted; late-reply guards; mock backends; Turkish.

## Out of scope
- Cloud sync, scheduled or automatic backups, incremental backups, encryption of the archives, backups to the network, a shared per-device content store (Inbox), migrating saves between different apps.

## Acceptance criteria
- [ ] Rust tests (pure core with a fake filesystem and fake volume): backup layout and manifest contents; cache excluded; symlinks and special files handled safely; checksum verification and a corrupted archive is `invalid-backup`; restore keeps the previous data aside and rolls back on failure; hostile archives (absolute path, `..`, a link pointing out, huge size) are refused; `busy` for a running app; `needs-admin` rules; `ListAppData` sizes with unreadable parts; atomic rename; no space.
- [ ] `tst_*.qml` (mock): the Keep-saves question defaults to Keep and calls `Uninstall` with the right flag; the usage list; the backup and restore flows with each status; focus after every step; the admin/PIN flows; Turkish strings present.
- [ ] Screenshots of the new Storage sections and the flows, read against `04` §8.
- [ ] VM (lead run): `scripts/vm-saves-check.sh` using the `org.ruyaos.Test*` Flatpak apps (like `vm-session-check.sh`) and a hot-plugged USB stick (like `vm-storage-check.sh`): write a save as the profile, back up, delete the data, restore, the file is back byte for byte; backup refused while running; hostile archive refused; uninstall with keep leaves the data, reinstall sees it; Outcome `Verified: host (vm pending: vm-saves-check.sh)`.
- [ ] The developer guide chapter `saves-and-data.md` is updated: the "planned" notes about backup become "built" with the exact behaviour; `docs/developers/README.md` status updated.
- [ ] `.\scripts\dev.ps1 test` and `shots` ALL GREEN; `systemd-analyze security` of `ruya-store` not worse (numbers in the Outcome).

## Docs to update
- Spec 03 §4.5a and the Store/Storage paragraphs, the XML contracts, `docs/developers/saves-and-data.md`, `docs/dev-setup.md`.

## Hints
- Extract with a small, audited code path; consider `tar` (the system one, as root, with `--no-same-owner`, `--no-absolute-names`, a checked file list first) versus the `tar`/`zstd` crates: whichever, test the hostile cases.
- The restore of another profile's data must run extraction as that profile's Unix user (drop privileges) so a hostile archive cannot write outside its home.
- A backup is read by people on other machines too: keep the manifest human-readable and the archive a plain tar.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
