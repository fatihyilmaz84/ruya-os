# T-163 — `ruya-library` in the image: installed Flatpaks over the real bus

Status: done · Phase: 2 · Depends: T-112, T-149 · Area: services, image · Size: M · Owner: builder

## Goal
On the console, Home's Recent row and the Games page list the Flatpak apps and games really installed on the system (from the Store), served by `ruya-library` over the system bus, instead of the mock.

## Read first
- `docs/specs/03-services-and-apps.md` §5 (Library row), ADR-004 in `00-overview.md`
- `api/dbus/org.ruyaos.Library1.xml`; `services/ruya-library/src/*`; `shell/src/library/DBusLibraryBackend.*`
- `services/CLAUDE.md`, `image/CLAUDE.md`; packaging to copy: `ruya-store` (Containerfile lines, `org.ruyaos.Store1.conf`, its unit's hardening)

## Scope
1. **Lead decision (2026-11-03), record it in spec 03 §5:** the image's `ruya-library` serves the **system Flatpak installation only** (`/var/lib/flatpak`, readable by everyone), as a system service under its own system user with `ProtectHome=yes`. Steam libraries live in each profile's home; reading them waits for a per-profile design (Inbox). So in the image the Steam source is off: no `RUYA_LIBRARY_HOME`, and `steam_roots` finds nothing.
2. **Packaging:** Containerfile installs the binary; a system unit (copy `ruya-store`'s hardening, minus what it needs for installing); bus policy `org.ruyaos.Library1.conf`: only the service user owns the name, only `ruya-shell` and root call it.
3. **Fresh list after the Store changes something:** when an install, update or uninstall finishes, the list must change without a reboot. Pick the simplest correct way (watch `/var/lib/flatpak/exports` with inotify, or `ruya-store` calls `Rescan`; say which and why in the Outcome) and emit `ItemsChanged`.
4. **VM check** `scripts/vm-library-check.sh` (copy `vm-store-check.sh`): over `busctl` as `ruya-shell`, `ListItems` returns the installed Flatpaks with `kind` from their desktop entry; installing a small Flathub app through `Store1` makes `ItemsChanged` fire and the app appear; uninstalling removes it; a call from another user is refused.
5. The shell's `DBusLibraryBackend` against the real service: in the same VM run, a VM screenshot (`scripts/vm-screenshot.ps1`) of Home or the Games page shows the installed item.

## Out of scope
- Steam games in the image, `last_played` (no source yet: stays 0), art from Flathub's appstream (later), launching (T-162, T-147).

## Acceptance criteria
- [ ] Rust test for the change detection logic (pure part; the inotify or Rescan glue may be untested on Windows, say so); `dev.ps1 test` ALL GREEN.
- [ ] VM (this task): image built, `RUYA_BOOT_OK`; `vm-library-check.sh` ALL PASSED (each item of Scope 4 a check).
- [ ] VM screenshot of the shell showing a real installed item, reviewed (attach the path in the Outcome).
- [ ] `systemd-analyze security ruya-library` exposure recorded in the Outcome.

## Verification
```powershell
.\scripts\dev.ps1 test
```
Then the image recipe in `docs/dev-setup.md`, `scripts\smoke-test.ps1`, `vm-library-check.sh` over SSH.

## Docs to update
- `03-services-and-apps.md` §5, `01-platform.md` (services list), `docs/dev-setup.md` (new check), the Library1 XML header ("Served by …").

## Hints
- Steam per profile is a separate design item (Inbox, lead): do not try it here.
- Pairs well with T-160 (one image build); say so in both Outcomes if you do both.

## Outcome
Verified: vm (image 0.0.30-t163 built and booted, `RUYA_BOOT_OK 0.0.30-t163`; paired with T-160, one image build covers both). Host: `dev.ps1 test` ALL GREEN (271 QML passed, 22 skips, Rust incl. 4 new `watch` tests).

**What was built.** `ruya-library` is in the image: Containerfile installs the binary and enables `ruya-library.service`; sysusers creates the system user `ruya-library`; the unit runs as that user with `ProtectHome=yes`, `PrivateNetwork`, `AF_UNIX` only, no capabilities, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`; bus policy `org.ruyaos.Library1.conf` lets only that user own the name and only `ruya-shell` and root call it. Image serves the system Flatpak installation only (lead decision, recorded in spec 03 section 5); no Steam source.

**Fresh list: polling, not inotify or a `Rescan` from `ruya-store`.** `watch.rs` (pure `fingerprint` of `/var/lib/flatpak/app` and `exports/share/applications` names, plus `Watcher`) is looked at every 2 s by a thread in `main.rs`; on a change it scans again and sends `ItemsChanged` only if the list differs. Why: no new dependency (inotify crate is Linux-only, not testable on this host), no coupling to the Store, and it also sees installs done with `flatpak` directly. The polling loop is glue and not unit-tested on Windows; the pure part has 4 tests. Revert test: making `fingerprint` return an empty list makes `install_and_uninstall_change_the_fingerprint` and `the_watcher_reports_only_real_changes` fail.

**Found in the first VM run:** `flatpak list` as `ruya-library` with `HOME=/nonexistent` fails with "Read-only file system" (ListItems stayed empty); `HOME=/tmp` (the unit's PrivateTmp) fixes it. Fixed in the unit.

**VM results** (`vm-library-check.sh check`, ALL CHECKS PASSED, 27 PASS): service active as its own uid, not root; ListItems equals `flatpak list --system --app`, no Steam items; Install through Store1 -> listed after about 2 s with `kind` game (from `Categories=Game;`), source flatpak, launch spec; `ItemsChanged` fired on install (0 -> 1) and on uninstall (2 -> 3); a second app has kind app; `Rescan` of an unchanged list sends nothing; `nobody` and the `ruya-library` account itself get "Access denied", root may call. The title is "TestGame" because the test repository has no appstream data (flatpak derives it from the id). `busctl monitor` needed `stdbuf -oL` or its output was buffered and signals looked missing.

**Security:** `systemd-analyze security ruya-library`: overall exposure 0.8 SAFE.

**Shell screenshot (VM):** `output/vm-shots/library-games.png` in the T-163 worktree (Games page shows the installed "TestGame" installed with `flatpak install`, picked up live by the watcher, no reboot); the file is in the git-ignored `output/` and was reviewed. `home.png` showed "Your library is empty" with two apps installed: Home's row is Recent (needs `last_played` > 0, which stays 0 here), so installed items appear on Games, not Home.

**Also:** `scripts/vm-update-check.sh`'s `call` helper only understood `s "..."` replies; Update1 methods return `ss`, so Check/Download reported FAIL although they worked. Fixed the sed (see T-160).

Files: api/dbus/org.ruyaos.Library1.xml, services/ruya-library/src/{watch,lib,main,dbus,flatpak}.rs, image/Containerfile, image/rootfs/usr/lib/systemd/system/ruya-library.service, image/rootfs/usr/share/dbus-1/system.d/org.ruyaos.Library1.conf, image/rootfs/usr/lib/sysusers.d/ruyaos.conf, scripts/vm-library-check.sh, docs/specs/01, 03, docs/dev-setup.md.

Follow-ups (Inbox lines in the HANDOFF): Steam per profile; Home's empty state when installed items have no `last_played`; Store1 reports `already-installed` for an app removed behind its back with `flatpak uninstall` (its installed cache is stale).
