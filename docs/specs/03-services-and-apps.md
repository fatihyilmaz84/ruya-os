# RuyaOS — System Services, Apps, Media & Gaming

Status: **Draft v1** · Parent: [00-overview](00-overview.md)

## 1. Profiles & security (ADR-004)

### 1.1 Model
- A profile is a Unix user `ruya-p<N>` with home `/var/home/ruya-p<N>` (0700). Display name, avatar, role and PIN hash live in one root-only file, `/var/lib/ruyaos/profiles.toml` (0600, written atomically). Ids are never reused. Implemented in `services/ruya-profiles`; the contract is `api/dbus/org.ruyaos.Profiles1.xml`.
- Roles: **Admin** (one or more; the first profile created in OOBE) and **Standard**. There's also **Guest**, whose user is created on demand and whose home is wiped at logout.
- PIN: optional for Standard, mandatory for Admin, never for Guest. 4–6 ASCII digits, stored as an argon2id hash and verified only by `ruya-profiles`. After 5 failures, exponential back-off from 30 s up to 1 h. The counter is shared by every PIN check (sign-in, admin authorisation, PIN change) and lives in memory, so a service restart resets it. The first profile (OOBE) must be an admin. Later profiles need admin credentials, passed explicitly in v1 and via polkit from Phase 2.
- Admin-only actions (polkit `org.ruyaos.admin`): OS update/rollback/channel, add/remove remotes, install system-wide apps, create/delete profiles, factory reset. The shell asks for the admin PIN, which `ruya-profiles` turns into a short-lived polkit authorization.
- **Rename and delete (T-118 service, T-131 UI).** `RenameProfile(actor_id, actor_pin, id, name)`: the actor is an admin or the profile itself and is checked with its own PIN; the name follows the create rules (trimmed, 1-32 characters, no control characters). `DeleteProfile(admin_id, admin_pin, id)`: admin only; refused with `not-allowed` for the last admin and for the active profile; it runs `userdel --remove` (the Unix user and its home are gone, there is no "keep data" option) and, if that fails, answers `failed` and leaves the store unchanged. The store is written first and `userdel` runs after it; a failed `userdel` puts the profile back (a store-write failure therefore never leaves a listed profile without its Unix user; a leftover user after a double failure is harmless, since ids are never reused). Both count their PIN checks towards the shared lockout, and a deleted profile loses its lockout state. Ids stay unique forever.
- **VerifyAdmin (T-135).** `VerifyAdmin(admin_id, admin_pin)` answers `ok` when the id is an admin and the PIN matches, `not-allowed` otherwise (unknown id or not an admin), and changes nothing; it counts towards the shared lockout. The shell uses it to gate actions of other services behind an admin PIN (the system rollback).
- Locking: on profile switch, on idle timeout (configurable), and on resume from suspend if the profile has a PIN.

#### UI flows (as built, T-105, T-131)
Settings -> Profiles lists the profiles (colour, name, role, PIN yes/no, "You" for the active one) and offers:
- **Add profile** (admins only): an inline form with Name (the on-screen keyboard), Role (Standard or Guest) and, for Standard, "Protect with a PIN". "Create profile" then collects the new PIN twice (only for a Standard profile with a PIN) and the admin's own PIN, and calls `CreateProfile` with the active admin's id and that PIN.
- **Change my PIN / Set a PIN** (Admin and Standard): the current PIN (only if there is one), then the new PIN twice, then `SetPin`.
- **Remove my PIN** (Standard with a PIN only; an Admin cannot remove theirs, so the row is hidden): the current PIN, then `SetPin` with an empty new PIN.
- **Rename and Delete** (T-131): Accept on a profile row shows two rows under the list, "Rename <name>" and "Delete <name>" (hidden when the rule forbids them; the Guest entry shows neither). Rename is offered to an admin for any profile and to a standard profile for itself: the on-screen keyboard, pre-filled with the current name, then the actor's PIN (skipped when the actor has none), then `RenameProfile`. Delete is offered to an admin for any profile except the active one and the last admin: a confirmation ("Delete <name>? Their saved data and settings are removed. This can't be undone.", focus on Cancel; the same dialog as the power actions), then the admin's PIN, then `DeleteProfile`. After a rename, focus stays on that profile's row; after a delete it moves to the row that took its place (the previous row at the end of the list). Replies go through the same status messages as below.

PINs are collected by the PIN pad in `collect` / `collect-confirm` mode (it calls no service); a mismatched confirmation shows "PINs don't match" and starts over. Every contract status maps to a message in the pane: `wrong-pin` ("%n attempt(s) left"), `locked-out` ("Try again in N s"), `invalid`, `not-allowed`, `failed`, plus `pin-required` and `unknown-profile`. `SwitchTo`, `CreateProfile` and `SetPin` all return `attempts_left` and `retry_after_secs` (meaningful for `wrong-pin` and `locked-out`, 0 otherwise), so the pane shows the counts straight from the reply. The mock enforces the same rules as `service.rs` (name 1-32 characters after trimming and no control characters, role, PIN format, admin check, the shared lockout counter with doubling back-off).

### 1.2 Isolation guarantees (acceptance)
- A profile can't read another profile's home (0700 homes, verified by test).
- Apps run as the profile's user inside Flatpak. Nothing third-party runs as root or as `ruya-shell`.
- Without FDE (01 §3.4), the documentation must say plainly that physical access bypasses PINs.

### 1.3 Parental controls (later)
Use `malcontent` with AppStream OARS ratings: per-profile age limit for store and launch, plus a "requires admin to install" toggle.

## 2. Devices (`ruya-devices`)

### 2.1 Controllers
- Handled by the input daemon (ADR-003). In-kernel drivers: `xpad` (Xbox wired), `hid-playstation` (DualSense), `hid-sony` (DS4), `hid-nintendo`. Optional: `xone` (Xbox wireless dongle), `xpadneo` (Xbox BT extras).
- Pairing over BlueZ D-Bus: Settings → Controllers → "Pair new" shows how to put each controller into pairing mode, then scans and auto-trusts.
- Player assignment: the first controller to press Accept on the profile picker becomes that profile's player 1. Battery level comes from `upower` and is shown in the overlay. Low battery shows a toast.
- A button-test and stick-calibration screen. Remapping is per profile and stored by the input daemon.

### 2.2 Storage
- udisks2 auto-mounts removable media for the active profile (`/run/media/<user>/<label>`). Supported filesystems: ext4, exFAT, FAT32, NTFS (read-write), Btrfs.
- On insert, a toast offers **Browse media**, **Install package** (only if a `.flatpak`/`.flatpakref` is present; asks for the admin PIN), or **Eject**. Nothing runs automatically.
- Settings → Storage shows usage per app (Flatpak installed size plus `~/.var/app/<id>`) and lets you uninstall or clear data.
- Optical (stretch): audio CD and data-disc detection only. Video DVD/Blu-ray playback is delegated to an app (e.g. VLC/Kodi Flatpak). We don't ship libdvdcss or AACS keys.

### 2.3 Audio
- PipeWire + WirePlumber. `ruya-devices` exposes sinks (HDMI/DP per port, analog, USB, Bluetooth), the default sink, and per-role volumes. Contract: `api/dbus/org.ruyaos.Devices1.xml`, interface `org.ruyaos.Devices1.Audio` (`ListSinks`, `SetDefaultSink`, `SetChannelVolume`, properties `MasterVolume`, `Muted`, `ChannelVolumes`; network and Bluetooth become sibling interfaces on the same object). The shell side (mock and D-Bus client, Settings -> Audio) is built (T-114). The service is built (T-128, `services/ruya-devices`): a pure core with the policy below, PipeWire read through `pw-dump` and driven through `wpctl`. **Followed by events, not polled (T-133, `events.rs`):** one long-running `pw-dump --monitor --no-colors` child prints a JSON array per change batch; batches that only update PipeWire clients are skipped (the monitor is a client itself and re-reports clients hundreds of times a minute), and a quiet burst of the rest (100 ms debounce) triggers one refresh, so changes made from outside (`wpctl`, hot-plug) reach the shell within a second and an idle system spends nothing. If the monitor dies (PipeWire restarted) it is started again after 1 s, doubling to 30 s, with one refresh on every reconnect, channel levels persisted in `$STATE_DIRECTORY/audio.toml`. The kind of an output comes from `device.api`/`device.bus`/the node name and is `analog` when unsure; applying `ambient` and `media` to app streams is not done yet (only `ui`, in the shell). The Linux shell uses it over D-Bus by default (`RUYA_SERVICES=mock` for the mock).
- Policy: the most recently connected headset or BT device becomes the default. On disconnect, fall back to the previous one. Never interrupt playback; streams move.
- HDMI passthrough (AC3/DTS/TrueHD) is enabled per sink in Settings → Audio (Phase 4).

### 2.4 Display
- Mode list and switching via the compositor (KMS). Default is the TV's preferred mode, capped at 4K60 for the shell.
- **Refresh-rate matching** for video apps (Phase 4): when a fullscreen surface requests a content rate (via `wp_content_type`/frame-rate hint, or an app-specific integration), switch to 23.976/24/25/50 Hz. Opt-in.
- HDR/VRR are stretch goals and depend on ADR-002 (gamescope supports both; QtWaylandCompositor support is unverified and needs a spike).

### 2.5 Network
NetworkManager over D-Bus: Ethernet status, Wi-Fi scan/connect (WPA2/3-Personal; Enterprise is out of MVP), captive-portal detection (NM connectivity check → open a portal page in a minimal web view, Phase 3+), proxy (later).

**As built (T-129, shell side only):** the contract is the `org.ruyaos.Devices1.Network` interface in `api/dbus/org.ruyaos.Devices1.xml` (`State`, `Primary`, `ListWifi`, `Scan`, `Connect`, `Forget`, `NetworksChanged`; statuses `ok`, `unknown-network`, `wrong-password`, `unsupported`, `invalid`, `failed`). The shell has the `Network` singleton (`shell/src/network`, mock by default on every OS, D-Bus client unverified) and Settings → Network (`NetworkPane.qml`): status row, Wi-Fi list, rescan, a Forget row per saved network, masked password entry. 

**As built (T-132, `ruya-devices`, `network.rs` + `networkmanager.rs`):** the service implements the interface on the same object as the audio part, over NetworkManager's own D-Bus API with zbus (no `nmcli`, no polling: NM's signals, debounced, drive `NetworksChanged` and the property changes). `State` comes from NM's `State` and `Connectivity` (`limited` for local-only, portal and failed checks); `Primary` is the active connection with its kind, name and IPv4 address; the Wi-Fi list has one entry per SSID (strongest signal wins) with `known`/`active` flags; `Connect` and `Forget` only ever touch Wi-Fi connections and map NM's failures to `wrong-password`, `unknown-network`, `unsupported` (enterprise) and `failed`. A password goes into one D-Bus call and into no log or error. NM authorizes through polkit: see `01-platform.md` for the rule. The Linux shell uses the service by default (`RUYA_SERVICES=mock` for the mock). Real Wi-Fi is not exercised in the VM (QEMU has none); the Wi-Fi rules are proven by unit tests and the fake.

### 2.6 HDMI-CEC (stretch)
Most PC GPUs don't expose CEC. Supported only with a USB-CEC adapter (Pulse-Eight) via `libcec`: TV remote D-pad → input daemon; standby/power sync.

## 3. Logging, crashes, telemetry
- journald is the only log store. `ruya-*` services log in structured form.
- Crashes go to `systemd-coredump`. The shell shows "App X closed unexpectedly". Uploading a report is opt-in.
- **No telemetry by default.** Any future metrics need opt-in in OOBE and a public data list.

## 4. Applications (ADR-005)

### 4.1 Format & runtime
- Only Flatpak. Installs are system-wide (`/var/lib/flatpak`) so they're shared by profiles. App data is per profile in `~/.var/app/<id>`.
- Metadata comes from AppStream (`metainfo.xml`). We read the standard fields (name, summary, description, screenshots, categories, `content_rating`, `<supports>`/`<recommends><control>`, releases) plus **RuyaOS custom keys**:
  ```xml
  <custom>
    <value key="x-ruya-hero">https://…/hero.webp</value>
    <value key="x-ruya-logo">https://…/logo.webp</value>
    <value key="x-ruya-launch-mode">fullscreen|gamescope|default</value>
    <value key="x-ruya-controller">full|partial|none</value>
  </custom>
  ```
- If art is missing, generate a tile from the icon, name and a dominant-colour gradient.
- Launch: `ruya-session` runs `flatpak run <id>` in the profile's user manager with `WAYLAND_DISPLAY` pointing at that profile's socket. Fullscreen is enforced by the compositor for non-overlay surfaces.
- **Contract** `api/dbus/org.ruyaos.Session1.xml`: `Launch(app_id, profile)` → `(status, instance)`, `Stop(instance)` → `status`, `ListRunning()`, signals `AppStarted` and `AppExited(instance, app_id, exit_code, reason)` with reason `quit | crashed | killed | launch-failed`. The profile argument is trusted (only `ruya-shell` and root may call); the service refuses non-profile accounts. Statuses are listed in the XML.
- **Shell side (T-138):** `Session` singleton (`shell/src/session/`, the Store pattern) with `running` (records `{instance, appId, profile, started, state}`), `launch`, `stop`, `instanceOf` and the signals. The mock knows `org.example.*` and `crashy` (exits `crashed`), `nolaunch` (exits `launch-failed`, never runs) and checks profiles against `Profiles`. `Shell.qml` shows the toast "<app> stopped unexpectedly" for `crashed` and `launch-failed`, never for `quit`. The D-Bus client is unverified until `ruya-session` exists (T-139).

- **Service side (T-139, dev mode only):** crate `services/ruya-session`. The core (`session.rs`) holds the instance registry and the state machine `starting -> running -> stopping`; an exited instance is reported once and removed. One instance per (profile, app id); the unit name is the instance name. Checks, in order: `invalid` (app id outside the Flatpak id grammar, profile id outside `[A-Za-z0-9_-]`), `unknown-profile` (`ProfileDirectory`: only ids `Profiles1.ListProfiles` returns, mapped to `ruya-<id>`; `root` and `ruya-shell` never qualify), `already-running`, `unknown-app`. Exit reasons: after `Stop`, a signal exit is `killed`, anything else `quit`; otherwise `launch-failed` (code -1) if it never reached running, `killed` for a signal, `quit` for 0, `crashed` for the rest. An app that ignores `Stop` is killed after 5 s. The OS is behind `Spawner`; the real one (`systemd-run --user --machine=ruya-<id>@.host --unit=ruya-app-<user>-<app>.service ... -- flatpak run <id>`) exists only as the tested command builder `spawner::launch_command`. Runs with `--session` over a fake spawner; **not in the image** (no unit, policy or Containerfile change) until the VM task after T-130.

### 4.2 Sources (Flatpak remotes)
| Remote | Trust | Default | Notes |
|---|---|---|---|
| `ruyaos` (Official) | Our GPG key; curated | On | Our apps and curated metadata overrides for Flathub apps (art, controller tags) |
| `flathub` (Community) | Flathub keys | On, filtered | Store hides apps lacking `x-ruya-controller` or `<control>gamepad</control>` unless "Show all apps" is enabled |
| `ruyaos-beta` / developer remotes | Their own keys | Off | Admin enables; red "Developer" badge |

Every app page shows its source badge. Unsigned remotes are refused.

**As shipped (T-140):** the image has `flathub` as a system remote, signed, and no `fedora` remote (Fedora's OCI remote has no AppStream names). `fedora-flathub-remote` supplies the `.flatpakrepo` with Flathub's key (its filter file is empty, i.e. unfiltered); `ruya-flathub-remote.service` (oneshot, once, marker `/var/lib/flatpak/.ruya-flathub-initialized`, no network needed) adds it and removes `fedora`/`fedora-testing` from systems that had them, and `flatpak-add-fedora-repos.service` is masked. The `ruyaos` remote does not exist yet.

### 4.3 Store service (`ruya-store`)
Wraps libflatpak and libappstream. D-Bus `org.ruyaos.Store1`: `Search`, `GetApp`, `Install`, `Update`, `Uninstall`, `Rollback(id, commit)`, `ListRemotes`, `AddRemote` (admin), plus progress and error signals. There's a single transaction queue, and updates run when idle. Errors (signature, missing runtime, disk full, network) map to user-facing messages.

The contract is `api/dbus/org.ruyaos.Store1.xml`. Differences from the list above: `Install`/`Uninstall`/`Update`/`Rollback` answer `(status, job)`; progress and errors are the `JobProgress` and `JobFinished` signals (error kinds are `JobFinished` statuses `network`, `signature`, `missing-runtime`, `disk-full`); `ListInstalled` and `InstalledChanged` were added; since T-148 `Search(query, options)` takes `controller` (`any` | `gamepad`: controller `full` or `partial` only) and `limit`, and `CatalogChanged` (not `InstalledChanged`) tells the clients to search again. The shell side is `shell/src/store` (on `InstalledChanged` the `Store` reads `ListInstalled` and patches the `installed`/`updateAvailable` flags of the apps it holds, with no new `Search`; on `CatalogChanged` it searches again; `Store.controllerFilter` (`any` default, `gamepad`) is passed to `Search` for `Store.search()`, the catalogue stays whole; the `Store` singleton, D-Bus by default on Linux since T-134, `RUYA_SERVICES=mock` for the mock, the mock elsewhere); its D-Bus client does not call `GetApp`, `Rollback`, `ListRemotes` or `AddRemote` yet.

**As built (T-134, `services/ruya-store`):** it drives the `flatpak` command line (`--system --noninteractive`, as root, English messages) instead of libflatpak; the AppStream data flatpak keeps per remote (`/var/lib/flatpak/appstream/<remote>/<arch>/active/appstream.xml.gz`) is read with a pure-Rust XML parser (name, summary, description, developer, `content_rating` to the OARS summary, `<control>gamepad` and `x-ruya-controller`, icon, `x-ruya-hero`/`x-ruya-logo`). An app a remote lists without AppStream data is shown under the last part of its id. `source` comes from the remote (`ruyaos` official, `flathub` community, anything else developer). Permissions come from the app's `metadata` (`flatpak remote-info --show-metadata`) and are read by `GetApp` on first use, not for the whole catalogue (a remote can have hundreds of apps); the lists carry the ones already read. Core rules: one transaction queue, jobs run one at a time in order, `busy` for an app that already has a job queued or running, `JobProgress` never decreases (0 at the start, 100 at the end; since T-140 the percentages in between come from giving `flatpak` a pseudo-terminal, opened with `rustix`, 200 columns wide, because it draws its progress bar only on a terminal; the output is cut into lines at carriage returns and newlines, escape codes are stripped, and an "n/m" in the line makes the percentage the share of the whole transaction, so the runtime and the app do not each run 0-100), error text maps to `network`, `signature`, `missing-runtime`, `disk-full` or `failed`, `InstalledChanged` comes before `JobFinished`. Every id, remote name, URL and commit that reaches the command line is validated first. `Uninstall(delete_data=true)` removes `~/.var/app/<id>` of every profile home under `/var/home` as the home's owner (`rm -rf` after `setuid`), so a symlink a profile planted cannot make root delete anything else. `AddRemote` is for root, or for the shell while the active profile (per `Profiles1`) is an admin; it never passes `--no-gpg-verify` and removes a remote that ended up unsigned (`invalid`). The catalogue is read once after start (a background thread) and again after every successful job and `AddRemote`. `InstalledChanged` is sent when the installed set or an update flag changed (every job that changed one, and a read that finds a difference); `CatalogChanged` only after the first read, after the AppStream refresh and after `AddRemote`, never for a job. After the first read and after every `AddRemote` the service runs `flatpak update --appstream --system <remote>` for each enabled remote and reads the catalogue again (`CatalogChanged` after both reads); without a network it logs once and keeps the cached data. Updates are not checked on a schedule. The unit is `ruya-store.service` (system, root, exposure 3.3 OK; it needs a larger capability set and network than `ruya-profiles`), the policy lets only root own the name and only `ruya-shell` and root call it. Checked in the VM with `scripts/vm-store-check.sh` (`dev-setup.md`).

### 4.4 Permissions
- Flatpak permissions are **static**. The app page shows them in plain language before install ("Uses network", "Reads your Downloads folder", "Accesses all devices"). High-risk permissions (`--device=all`, `--filesystem=host`, `--talk-name=org.freedesktop.Flatpak`) get a warning and, for Standard profiles, need the admin PIN.
- Runtime prompts exist only for portal-mediated access (file chooser, camera, screenshot). We need a **portal backend** (`xdg-desktop-portal-ruya` or a QML-themed reuse of an existing backend) so portal dialogs render in the shell, controller-navigable. **Gap to spike in Phase 3.**
- Admins can review and override permissions per app (a Flatseal-like view).
- **As built (T-111, `AppDetailPage.qml`):** the app page lists the permissions in plain words (`Plays sound`, `Uses the network`, ...); `all-devices`, `host-files` and `session-bus` carry a warning `High risk` badge and warning-coloured text. The admin PIN for high-risk installs is not enforced yet (Inbox). Install / Update / Open (disabled until the session service exists) and Uninstall with an "Also delete my data" toggle (Cancel is the default); progress shows a bar with the phase, and errors (`network`, `signature`, `missing-runtime`, `disk-full`, `busy`, else generic) are shown inline.

### 4.5 Acceptance (Phase 3)
Install, launch, update, roll back and uninstall (with "also delete data" option) a Flathub app and our sample QML app entirely by controller. Bad signature and missing runtime produce clear errors. Uninstall leaves no files in `/var/lib/flatpak` for that app.

### 4.6 SDK (Phase 7)
- An app template: Qt Quick + Flatpak manifest + AppStream with `x-ruya-*` keys + controller-nav QML helpers (packaged as a QML module in a Flatpak extension).
- Guidelines: 10-foot UI, focus rules (02 §4.3), safe area, how to respond to the Guide button (apps get `xdg_toplevel` suspend/visibility events).
- Publishing goes through a PR to the `ruyaos` remote's manifest repo (Flathub-style review).

## 5. Gaming

| Item | Approach |
|---|---|
| Steam | Flathub `com.valvesoftware.Steam` (redistribution-safe), launched in Big Picture **inside gamescope** (`x-ruya-launch-mode=gamescope`). Proton versions are managed in Steam itself. |
| Steam Input | Steam grabs controllers too. With ADR-003, InputPlumber exposes virtual Xbox-style pads that Steam consumes normally. Verify no double input in the Phase 5 test matrix. |
| Non-Steam Windows games | Heroic / Lutris Flatpaks (they use umu-launcher/Proton). We don't build our own Proton front-end. |
| Emulation | RetroArch Flatpak plus a curated cores list. No ROMs or BIOS files are shipped. ROM folders on USB or in `~/Games/roms` are detected by RetroArch, not by us. |
| Library | The shell's Games row lists installed Flatpak games, plus Steam games read from Steam's `libraryfolders.vdf`/`appmanifest_*.acf` (read-only) and launched via `steam steam://rungameid/<id>`. Served by `services/ruya-library` over `api/dbus/org.ruyaos.Library1.xml` (T-112: discovery core; D-Bus serving unverified, not yet in the image). Heroic integration is a stretch goal. |
| Saves | Stay where each app puts them (inside `~/.var/app/<id>` per profile). "Back up profile to USB" archives `~/.var/app` for that profile (Phase 6). Cloud saves are left to Steam etc. |
| Streaming | Moonlight (Flathub), Steam Link (Flathub), Xbox Cloud Gaming via a browser Flatpak in kiosk mode (stretch, controller passthrough to be tested) |
| Anti-cheat | Documented as unsupported where the game blocks Linux. |

**Acceptance (Phase 5):** a native Linux Steam game, a Proton game and a RetroArch game each launch from the RuyaOS library, play with a controller, open the Guide overlay and return, and keep their saves across an OS update and a rollback.

## 6. Media

| Need | Approach |
|---|---|
| Personal media servers | Jellyfin Media Player / Kodi Flatpaks (Kodi gives a 10-foot UI out of the box). Plex: use the Plex HTPC Flatpak if available, otherwise none. |
| IPTV | Kodi PVR IPTV Simple client (M3U/XMLTV) instead of building our own player |
| Commercial streaming | Browser Flatpak (Chromium-based, Widevine L3) in kiosk mode. Resolution is limited by the service, which we state in docs. |
| Local files | Kodi or VLC from USB or the network |
| HW decode | Host side is solved by ADR-009 (`mesa-va-drivers-freeworld`, `intel-media-driver`, `libva-nvidia-driver`). Flatpak apps need `org.freedesktop.Platform.ffmpeg-full`/`codecs-extra` and the GL/VA-API extensions, which `ruya-store` installs on first boot. Verify with `vainfo` inside the Flatpak sandbox. |

**Acceptance (Phase 4):** a 4K HEVC 10-bit file plays with HW decode on the mid tier (verified with `intel_gpu_top`/`radeontop`), audio switches to a BT headset mid-playback without stopping, and controller navigation works in Kodi and Jellyfin.

## 7. Licence compliance
- An SBOM (SPDX via `syft`) for every image and for our Flatpaks, generated in CI.
- A licence scan of our code and dependencies (`cargo deny`, REUSE/SPDX headers).
- An allow-list for firmware, codecs and NVIDIA blobs, with redistribution terms recorded (ADR-009). `LICENSE.md` points users at the SBOM.
- Qt: LGPLv3 modules dynamically linked. The shell is GPL-3.0-or-later (ADR-008), so linking QtWaylandCompositor (GPLv3) is fine.
