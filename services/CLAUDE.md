# services/ — rules for the Rust system services

Cargo workspace. Each service is a crate named `ruya-<name>` that serves `org.ruyaos.<Name>1` on the system bus. `ruya-profiles` is the reference implementation; copy its structure.

## Structure of a service crate

| File | Role |
|---|---|
| `src/lib.rs` | Module list and re-exports |
| `src/<logic>.rs` | **Pure core:** all rules, no I/O except through injected traits. Time is passed in (`now: Instant`), so lockouts and timeouts are testable. |
| `src/store.rs` (if state) | Persistence under `/var/lib/ruyaos/` with atomic writes (tmp + rename), root-only modes, and errors on corrupt data (never overwrite silently) |
| `src/<side_effect>.rs` | A trait for OS side effects (e.g. `Accounts`), a no-op implementation for tests and dev, and a Linux implementation behind `#[cfg(target_os = "linux")]` |
| `src/dbus.rs` | **Thin** zbus 5 adapter: converts types, calls the core, emits signals and property changes. No rules here. |
| `src/main.rs` | Parses `--session` (dev mode: session bus, no privileged side effects) and env overrides, then serves. |

## Rules

- **The contract comes first.** Write or extend `api/dbus/org.ruyaos.<Name>1.xml` before the code. Status strings in the XML header are stable API. Method and argument names must match exactly.
- **The served interface is tested against the XML (RUY-403).** Each service has `tests/contract.rs` that builds its `#[interface]` objects with the crate's fakes and calls `ruya_contract_test::assert_serves("org.ruyaos.<Name>1.xml", &iface, &[])`: every method (arguments in order, with direction and signature), property (type, access) and signal (signature) must equal the file's, argument names and annotations aside. A new interface or a new `api/dbus` file fails `ruya-contract-test/tests/registry.rs` until it has such a test (or is listed there as not served). A draft contract built member by member (`Input1`) lists the members not built yet in its test (`NOT_BUILT`); the test fails when a listed member is served, so building one means taking it off the list.
- **The keys of an `a{sv}` record are tested against the XML too (RUY-885).** `ruya_contract_test::parse_records` reads every `<Name> record (a{sv}), keys:` comment block (key, signature, description; "absent" in a key's description makes that key optional, in a block's heading every key of the block), and `assert_record_served(file, name, samples)` fails on a served key the XML lacks, a missing always-present key, a different signature, or a documented key no sample serves. `ruya-library` uses it (Library1 `Item`); the other services' records (Input1, Play1, Session1, Store1 parse already) adopt it by building their records through the service's own function.
- **Tests:** every rule in the pure core has a unit test. Tests must run on Windows (`cargo test`), so keep Linux-only code out of the core.
- **Both targets must be clean:** `dev.ps1 rust` runs clippy for Windows *and* `x86_64-unknown-linux-gnu` with `-D warnings`. Run `cargo fmt` before committing.
- **No `unwrap()`/`expect()`** on paths reachable from D-Bus input. Return a status string instead (`invalid`, `failed`, …). `expect()` is fine only where the invariant has just been checked, with a message saying so.
- **Navigation keys are chosen by the Qt key they become through xkb, not by the evdev name** (RUY-583): `NavKey::evdev_code` in `mapping.rs`. Start is `KEY_COMPOSE` (xkb `Menu`, `Qt::Key_Menu`); `KEY_MENU` would be `XF86MenuKB`, `Qt::Key_MenuKB`, which no shell handler takes. Check a new key in the VM (`vm-input-check.sh start` is the pattern), because the off-Linux tests send Qt keys directly.
- **Secrets** (PIN hashes, tokens) never appear in D-Bus replies, logs or errors.
- `Cargo.lock` is committed and builds use `--locked`. A new dependency needs a one-line justification in the commit message. Prefer pure-Rust crates: they must build on Windows **and** in the Fedora image.

## Shared homes (look here before writing a helper)

A rule two crates need lives in one library crate, never copied into both: the `.play` format (manifest, file table, paths, limits, problem codes, `runner.json` and the runner hash in `runner.rs`, `sha256_of`/`sha256_hex`/`hex`/`is_lower_hex`) in `ruya-play-format`; art and video vetting and the art roles in `ruya-play-art`; signatures, keys, tiers and the trust record in `ruya-play-trust`; Flatpak's app-id grammar, the argument lists of the `flatpak` commands more than one service runs (`override`, `--reset`, `--show`) and the OARS severity table with its age label (`oars`, RUY-914: `ruya-store` rates AppStream with it, `ruya-play` a manifest, `ruya-play-format` validates against its table) in `ruya-flatpak` (pure; running them stays with each service); the ids the services share in `ruya-ids` (RUY-1008; pure, no dependencies: the profile-id rule `valid_profile_id`, `[A-Za-z0-9_-]`, 1 to 32 bytes, and the profile user name `user_of` / `profile_of_user`, `p3` <-> `ruya-p3`; Flatpak app ids stay in `ruya-flatpak`; a later shared id goes here too); the served-interface check in `ruya-contract-test`; file access below a folder someone else controls (a profile's home, an app's data), never through a link, in `ruya-fs` (RUY-911: a `Dir` handle walked with `openat` per component; read with a cap, atomic write, 0700 folders, remove, copy (reflink first) and rename a tree, `set_mode`, `read_link`; `kind` and `entries` (names and kinds, a link reported as a link) and `open_file(path)` for a caller with only a path; `ruya-session`, `ruya-library` (Steam's files), `ruya-play-launch`, `ruya-play-art` and `ruya-devices` use it); Valve's text KeyValues (`config.vdf`, `libraryfolders.vdf`, `appmanifest_*.acf`, `compatibilitytool.vdf`) in `ruya-vdf` (RUY-960; the one Steam VDF reader and writer, text in and out: ordered, repeated keys kept, case-insensitive lookups, `//` comments and unquoted tokens read; `ruya-session` and `ruya-library` use it, the file access stays `ruya-fs`'s). Inside a service, one module owns each rule (`ruya-play`'s `reconcile::open_ours` is the one origin check). A new rule a second crate will need goes into the library crate in the same branch.

## Integrating a new service into the OS (all three are needed)

1. A systemd unit in `image/rootfs/usr/lib/systemd/system/ruya-<name>.service`. Copy the hardening block from `ruya-profiles.service` (`Type=dbus`, `ProtectSystem=strict`, `NoNewPrivileges`, a minimal `CapabilityBoundingSet`, `SystemCallFilter=@system-service`, `UMask=0077`, …) and open only the paths it needs. Check it in the VM with `systemd-analyze security ruya-<name>`; aim for "OK" (`ruya-profiles` is 1.6).
2. A D-Bus policy in `image/rootfs/usr/share/dbus-1/system.d/org.ruyaos.<Name>1.conf`: only root owns the name, and only `ruya-shell` and root may call it. Its default context denies `own`, `send_destination` and the service's signals in writing (`scripts/lint-bus-policies.ps1` refuses a policy without them; copy `org.ruyaos.Profiles1.conf`).
3. `image/Containerfile`: install the binary in the `services-build` stage and add it to `systemctl enable`.

These are image changes: build the image and check them in the VM (`docs/dev-setup.md`; a `scripts/vm-<name>-check.sh` like `vm-profiles-check.sh`). A task is not `done` until the service runs there.

**Exception, `ruya-devices` (ADR-010):** it runs as a systemd *user* unit of `ruya-shell` (`image/rootfs/usr/lib/systemd/user/`, `ConditionUser=ruya-shell`) so it can reach the shell's PipeWire, and its D-Bus policy lets `ruya-shell` own the name instead of root. Use every hardening option a user manager accepts.
