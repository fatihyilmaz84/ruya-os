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
- **Tests:** every rule in the pure core has a unit test. Tests must run on Windows (`cargo test`), so keep Linux-only code out of the core.
- **Both targets must be clean:** `dev.ps1 rust` runs clippy for Windows *and* `x86_64-unknown-linux-gnu` with `-D warnings`. Run `cargo fmt` before committing.
- **No `unwrap()`/`expect()`** on paths reachable from D-Bus input. Return a status string instead (`invalid`, `failed`, …). `expect()` is fine only where the invariant has just been checked, with a message saying so.
- **Secrets** (PIN hashes, tokens) never appear in D-Bus replies, logs or errors.
- `Cargo.lock` is committed and builds use `--locked`. A new dependency needs a one-line justification in the commit message. Prefer pure-Rust crates: they must build on Windows **and** in the Fedora image.

## Integrating a new service into the OS (all three are needed)

1. A systemd unit in `image/rootfs/usr/lib/systemd/system/ruya-<name>.service`. Copy the hardening block from `ruya-profiles.service` (`Type=dbus`, `ProtectSystem=strict`, `NoNewPrivileges`, a minimal `CapabilityBoundingSet`, `SystemCallFilter=@system-service`, `UMask=0077`, …) and open only the paths it needs. Check it in the VM with `systemd-analyze security ruya-<name>`; aim for "OK" (`ruya-profiles` is 1.6).
2. A D-Bus policy in `image/rootfs/usr/share/dbus-1/system.d/org.ruyaos.<Name>1.conf`: only root owns the name, and only `ruya-shell` and root may call it.
3. `image/Containerfile`: install the binary in the `services-build` stage and add it to `systemctl enable`.

These are image changes: build the image and check them in the VM (`docs/dev-setup.md`; a `scripts/vm-<name>-check.sh` like `vm-profiles-check.sh`). A task is not `done` until the service runs there.

**Exception, `ruya-devices` (ADR-010):** it runs as a systemd *user* unit of `ruya-shell` (`image/rootfs/usr/lib/systemd/user/`, `ConditionUser=ruya-shell`) so it can reach the shell's PipeWire, and its D-Bus policy lets `ruya-shell` own the name instead of root. Use every hardening option a user manager accepts.
