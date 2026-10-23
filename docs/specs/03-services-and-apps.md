# RuyaOS — System Services, Apps, Media & Gaming

Status: **Draft v1** · Parent: [00-overview](00-overview.md)

## 1. Profiles & security (ADR-004)

### 1.1 Model
- A profile is a Unix user `ruya-p<N>` with home `/var/home/ruya-p<N>` (0700). Display name, avatar, role and PIN hash live in one root-only file, `/var/lib/ruyaos/profiles.toml` (0600, written atomically). Ids are never reused. Implemented in `services/ruya-profiles`; the contract is `api/dbus/org.ruyaos.Profiles1.xml`.
- Roles: **Admin** (one or more; the first profile created in OOBE) and **Standard**. There's also **Guest**, whose user is created on demand and whose home is wiped at logout.
- PIN: optional for Standard, mandatory for Admin, never for Guest. 4–6 ASCII digits, stored as an argon2id hash and verified only by `ruya-profiles`. After 5 failures, exponential back-off from 30 s up to 1 h. The counter is shared by every PIN check (sign-in, admin authorisation, PIN change) and lives in memory, so a service restart resets it. The first profile (OOBE) must be an admin. Later profiles need admin credentials, passed explicitly in v1 and via polkit from Phase 2.
- Admin-only actions (polkit `org.ruyaos.admin`): OS update/rollback/channel, add/remove remotes, install system-wide apps, create/delete profiles, factory reset. The shell asks for the admin PIN, which `ruya-profiles` turns into a short-lived polkit authorization.
- **Rename and delete (T-118, contract and service only; the UI comes later).** `RenameProfile(actor_id, actor_pin, id, name)`: the actor is an admin or the profile itself and is checked with its own PIN; the name follows the create rules (trimmed, 1-32 characters, no control characters). `DeleteProfile(admin_id, admin_pin, id)`: admin only; refused with `not-allowed` for the last admin and for the active profile; it runs `userdel --remove` (the Unix user and its home are gone, there is no "keep data" option) and, if that fails, answers `failed` and leaves the store unchanged. The store is written first and `userdel` runs after it; a failed `userdel` puts the profile back (a store-write failure therefore never leaves a listed profile without its Unix user; a leftover user after a double failure is harmless, since ids are never reused). Both count their PIN checks towards the shared lockout, and a deleted profile loses its lockout state. Ids stay unique forever.
- Locking: on profile switch, on idle timeout (configurable), and on resume from suspend if the profile has a PIN.

#### UI flows (as built, T-105)
Settings -> Profiles lists the profiles (colour, name, role, PIN yes/no, "You" for the active one) and offers:
- **Add profile** (admins only): an inline form with Name (the on-screen keyboard), Role (Standard or Guest) and, for Standard, "Protect with a PIN". "Create profile" then collects the new PIN twice (only for a Standard profile with a PIN) and the admin's own PIN, and calls `CreateProfile` with the active admin's id and that PIN.
- **Change my PIN / Set a PIN** (Admin and Standard): the current PIN (only if there is one), then the new PIN twice, then `SetPin`.
- **Remove my PIN** (Standard with a PIN only; an Admin cannot remove theirs, so the row is hidden): the current PIN, then `SetPin` with an empty new PIN.

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
- PipeWire + WirePlumber. `ruya-devices` exposes sinks (HDMI/DP per port, analog, USB, Bluetooth), the default sink, and per-role volumes. Contract: `api/dbus/org.ruyaos.Devices1.xml`, interface `org.ruyaos.Devices1.Audio` (`ListSinks`, `SetDefaultSink`, `SetChannelVolume`, properties `MasterVolume`, `Muted`, `ChannelVolumes`; network and Bluetooth become sibling interfaces on the same object). The shell side (mock and D-Bus client, Settings -> Audio) is built (T-114). The service is built (T-128, `services/ruya-devices`): a pure core with the policy below, PipeWire read through `pw-dump` and driven through `wpctl` (one poll per second, which also catches changes made from outside), channel levels persisted in `$STATE_DIRECTORY/audio.toml`. The kind of an output comes from `device.api`/`device.bus`/the node name and is `analog` when unsure; applying `ambient` and `media` to app streams is not done yet (only `ui`, in the shell). The Linux shell uses it over D-Bus by default (`RUYA_SERVICES=mock` for the mock).
- Policy: the most recently connected headset or BT device becomes the default. On disconnect, fall back to the previous one. Never interrupt playback; streams move.
- HDMI passthrough (AC3/DTS/TrueHD) is enabled per sink in Settings → Audio (Phase 4).

### 2.4 Display
- Mode list and switching via the compositor (KMS). Default is the TV's preferred mode, capped at 4K60 for the shell.
- **Refresh-rate matching** for video apps (Phase 4): when a fullscreen surface requests a content rate (via `wp_content_type`/frame-rate hint, or an app-specific integration), switch to 23.976/24/25/50 Hz. Opt-in.
- HDR/VRR are stretch goals and depend on ADR-002 (gamescope supports both; QtWaylandCompositor support is unverified and needs a spike).

### 2.5 Network
NetworkManager over D-Bus: Ethernet status, Wi-Fi scan/connect (WPA2/3-Personal; Enterprise is out of MVP), captive-portal detection (NM connectivity check → open a portal page in a minimal web view, Phase 3+), proxy (later).

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

### 4.2 Sources (Flatpak remotes)
| Remote | Trust | Default | Notes |
|---|---|---|---|
| `ruyaos` (Official) | Our GPG key; curated | On | Our apps and curated metadata overrides for Flathub apps (art, controller tags) |
| `flathub` (Community) | Flathub keys | On, filtered | Store hides apps lacking `x-ruya-controller` or `<control>gamepad</control>` unless "Show all apps" is enabled |
| `ruyaos-beta` / developer remotes | Their own keys | Off | Admin enables; red "Developer" badge |

Every app page shows its source badge. Unsigned remotes are refused.

### 4.3 Store service (`ruya-store`)
Wraps libflatpak and libappstream. D-Bus `org.ruyaos.Store1`: `Search`, `GetApp`, `Install`, `Update`, `Uninstall`, `Rollback(id, commit)`, `ListRemotes`, `AddRemote` (admin), plus progress and error signals. There's a single transaction queue, and updates run when idle. Errors (signature, missing runtime, disk full, network) map to user-facing messages.

### 4.4 Permissions
- Flatpak permissions are **static**. The app page shows them in plain language before install ("Uses network", "Reads your Downloads folder", "Accesses all devices"). High-risk permissions (`--device=all`, `--filesystem=host`, `--talk-name=org.freedesktop.Flatpak`) get a warning and, for Standard profiles, need the admin PIN.
- Runtime prompts exist only for portal-mediated access (file chooser, camera, screenshot). We need a **portal backend** (`xdg-desktop-portal-ruya` or a QML-themed reuse of an existing backend) so portal dialogs render in the shell, controller-navigable. **Gap to spike in Phase 3.**
- Admins can review and override permissions per app (a Flatseal-like view).

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
| Library | The shell's Games row lists installed Flatpak games, plus Steam games read from Steam's `libraryfolders.vdf`/`appmanifest_*.acf` (read-only) and launched via `steam steam://rungameid/<id>`. Heroic integration is a stretch goal. |
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
