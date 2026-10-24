# RuyaOS — Overview, Architecture & Decisions

Status: **Draft v1** (consolidated 2026-10-22 from the three research docs; see `docs/REVIEW.md`).
Companion specs: [01-platform](01-platform.md) · [02-shell](02-shell.md) · [03-services-and-apps](03-services-and-apps.md)

## 1. Vision

RuyaOS is an immutable, image-based Linux OS for living-room PCs. It boots straight into a full-screen, controller-first, "cinematic" console UI: fluid 60 FPS motion, frosted-glass layers, and UI sound. There's no desktop. From one place it runs apps, media clients, streaming clients and games, for several PIN-protected profiles.

### Principles
1. **Reuse before build.** Fedora bootc, Flatpak, PipeWire/WirePlumber, NetworkManager, BlueZ, udisks2, polkit, greenboot, InputPlumber/SDL. Custom code is limited to the console-specific layers: shell, session orchestration, and glue services.
2. **Image-based and recoverable.** The OS is one signed container image. Updates are atomic, and a failed boot rolls back automatically.
3. **Controller-first.** Every flow, including installation and first-boot setup, works with a gamepad alone.
4. **Measured polish.** "Cinematic" is defined by KPIs ([02-shell §8](02-shell.md)) that run on real hardware tiers.
5. **Gated phases.** No phase starts until the previous one meets its exit criteria. Dates are estimates, not commitments.

## 2. Scope

### MVP (end of Phase 5)
- Boot, update and rollback, installer, first-boot setup.
- Shell: home, library, settings, store, overlay (Guide button), notifications, volume OSD.
- Profiles with PIN, plus a guest profile. One admin.
- Controllers over USB and Bluetooth. Keyboard and mouse as a fallback.
- Network (Ethernet, Wi-Fi), audio output switching, USB storage.
- Apps from Flatpak remotes (official plus a filtered Flathub).
- Media: Jellyfin and/or Kodi, Plex if a Linux client exists, Moonlight, Steam Link.
- Gaming: Steam (Proton), RetroArch.

### Later / stretch
SDK and public developer programme, optical media, HDMI-CEC, HDR/VRR, cloud saves, parental controls UI, web-app runtime, custom "console bundle" format.

### Explicit non-goals
- Our own sandbox, package manager or display protocol.
- Proprietary DVD/Blu-ray decryption in the base image.
- Premium-streaming DRM parity with commercial TV OSes. Widevine L1 isn't available on Linux. Netflix and similar services run only via browser L3, at capped resolution.
- Anti-cheat titles that block Linux.

## 3. Target hardware

| Tier | Example | Expectation |
|---|---|---|
| Low | Intel NUC 8th–11th gen iGPU | 1080p, reduced effects, ≥ 30 FPS floor in transitions |
| Mid | Recent Intel Xe / AMD RDNA2+ APU mini-PC | 1080p/4K UI at 60 FPS, full effects |
| High | Desktop with discrete AMD or NVIDIA GPU | 4K60 UI, demanding games, HDR (later) |

All tiers are UEFI x86_64. NVIDIA needs the proprietary driver, which affects image build and Secure Boot ([01-platform §2.3](01-platform.md)).

## 4. Architecture

```mermaid
graph TB
  subgraph Image["Immutable OS image (fedora-bootc, /usr read-only)"]
    K[Kernel · Mesa/NVIDIA · firmware]
    SD[systemd · logind · polkit · greenboot]
    PW[PipeWire + WirePlumber]
    NM[NetworkManager · BlueZ · udisks2]
    INP[Input daemon<br/>InputPlumber or ruya-inputd]
    RS[Ruya services (Rust, D-Bus)<br/>ruya-session · ruya-profiles · ruya-store · ruya-devices]
    COMP[Compositor + Shell<br/>Qt Quick / QtWaylandCompositor]
  end
  subgraph State["Mutable state (/etc merged, /var persistent)"]
    HOME[/var/home/&lt;profile&gt;/]
    FP[/var/lib/flatpak/]
  end
  Apps[Flatpak apps & games<br/>(optionally inside gamescope)]

  K --> INP --> COMP
  INP -- virtual gamepads --> Apps
  COMP -- Wayland --> Apps
  COMP <-- D-Bus --> RS
  RS --> SD & NM & PW & FP & HOME
  Apps --> PW
```

### Components

| Component | Language | Responsibility |
|---|---|---|
| **ruya-shell** | QML + C++ | UI, the Wayland compositor (per ADR-002), focus/overlay, app windows, OSD |
| **ruya-session** | Rust | Launch/stop apps as the active profile's user, track running apps, suspend/resume hooks |
| **ruya-profiles** | Rust | Profiles, PIN verification and rate limiting, avatars, per-profile settings |
| **ruya-store** | Rust | Wraps libflatpak and AppStream: remotes, install/update/rollback, progress |
| **ruya-devices** | Rust | Facade over udisks2, BlueZ, NetworkManager and PipeWire (wpctl/libpipewire) for the shell |
| **Input daemon** | (reuse) | Grabs physical controllers, maps them (SDL GameController DB), re-emits virtual devices, routes to shell or game (ADR-003) |
| **ruya-update** | Rust (thin) | Drives `bootc upgrade`/`switch`/`rollback`, reports status, schedules reboot |

**IPC.** All shell↔service traffic goes over **D-Bus** (system bus, `org.ruyaos.*`) with `zbus` on the service side and QtDBus or generated C++ proxies on the shell side. Privileged actions (install system app, OS update, add repo, create profile) go through **polkit**. The shell gets an admin authorization after the admin PIN is checked by `ruya-profiles`. Each interface is versioned (`org.ruyaos.Store1`). Interface XML lives in `/api/dbus/` and is the contract between the QML and Rust teams.

## 5. Decision log (ADRs)

Status: **Accepted** · **Proposed** (recommendation, needs owner sign-off) · **Open** (needs a spike)

### ADR-001 — Base: plain `fedora-bootc` vs Universal Blue / Bazzite components — *Accepted (2026-10-22)*
Bazzite already ships Fedora-bootc images with NVIDIA variants, a gamescope console session, Steam and controller tooling. **Recommendation:** start from `quay.io/fedora/fedora-bootc` so the image stays minimal and understandable. Borrow specific, proven pieces (NVIDIA akmods layer, udev rules, InputPlumber packaging) from Universal Blue rather than rebasing on Bazzite. Revisit if Phase 0–1 effort runs high.

### ADR-002 — Compositor ownership — *Accepted: option A (owner, 2026-10-23); performance to be confirmed on hardware, option B is the fallback*
The shell must draw over running apps (Guide overlay, OSD, toasts), switch between apps, and control focus. Options:

| Option | Overlay over games | App switching | Effort | Licence |
|---|---|---|---|---|
| A. Shell **is** the compositor (QtWaylandCompositor, QML) | Native | Native | High | GPLv3 (or commercial) |
| B. gamescope + shell as client (OpenGamepadUI model) | Via gamescope's overlay atoms (Xwayland-centric) | Limited | Medium | BSD |
| C. Kiosk (cage / Weston kiosk-shell) + shell as client | No | No | Low | MIT |
| D. KWin (Plasma Bigscreen model) + shell as layer-shell client | Yes (layer-shell) | Via KWin scripting | Medium, heavy dependencies | GPL |

**Phase 0 uses C (cage)** to de-risk boot and session. **Recommendation for the product: A.** It's also the strongest fit for the cinematic UI, because effects can be applied to app surfaces. Games can still run *nested* in gamescope (as a Wayland client of A) to get FSR and frame limiting. Exit criterion for the spike: a Flatpak game runs fullscreen, the Guide button opens a blurred overlay over it at ≥ 55 FPS on the mid tier, and closing the overlay returns input to the game.

**Functional spike result (T-123, lead, 2026-10-23, in the VM): A works.** With Fedora's Qt 6.11 (`qt6-qtwayland`, already in the image, ships `QtWayland.Compositor`), `ruya-shell` ran as the compositor directly on KMS (`eglfs_kms`, llvmpipe, 1280×800 on `virtio-vga`), with the unchanged `Shell` as its bottom layer, a Qt test client fullscreen above it (xdg-shell), and the Shell's own Guide overlay moved above the client. Keys reached the client; Guide (Super, and the controller's `KEY_HOMEPAGE`) opened the overlay over the running client and the client got nothing while it was open; closing it returned the keys; when the client exited the shell took the screen and focus back. About 100 lines of QML (`shell/spike/Compositor.qml`). Found on the way, for the product path:
- **Device access.** Qt's eglfs opens DRM and evdev itself, with no logind `TakeDevice` (cage uses libseat). The DRM card already gets an ACL for the active session; input devices needed a `uaccess` udev rule. The product needs either that rule (the shell user then reads every input device, which is acceptable only because it is the session's sole UI) or logind-based device opening in a small platform plugin; decide in the follow-up task. VT switching and suspend/resume with eglfs are unexplored.
- **Client buffers.** llvmpipe has no `EGL_WL_bind_wayland_display`, so clients in the VM must use shm (software rendering); real GPUs use dmabuf/`linux-dmabuf`, untested here.
- **Key routing** belongs in C++ (an event filter in front of the client item) rather than QML `Keys`, so modifier-only keys and future InputPlumber routing (ADR-003) have one place.
- Not tested: Flatpak apps, gamescope nesting, Xwayland, blur over a client surface, per-profile sockets (ADR-004), frame rates.
**Decision (owner, 2026-10-23): option A is the product direction**, on the strength of this functional result. The performance half (≥ 55 FPS with the blurred overlay over a game on the mid tier) is still to be measured on hardware (B-003); if A fails it there, fall back to **option B** (gamescope with the shell as a client). Until the compositor session (T-130) replaces it, the image keeps booting cage.

### ADR-003 — Controller input arbitration — *Accepted (2026-10-22); Phase 0 uses a non-grabbing stopgap*
Wayland has no gamepad protocol, so games read evdev/hidraw directly. **Recommendation:** use **InputPlumber**, already used by ChimeraOS and handheld distros. It grabs physical devices, exposes virtual controllers to games, and exposes a keyboard/D-Bus target to the shell. When the overlay opens, the shell tells it to route input to the shell. Fallback: our own `ruya-inputd` in Rust (evdev `EVIOCGRAB` + uinput + SDL mapping DB). Steam Input must be configured so it doesn't double-handle controllers (see 03 §5).

*Phase 0 stopgap:* `services/ruya-inputd` translates gamepad buttons, D-pad and left stick into navigation keys on a virtual uinput keyboard. It **doesn't grab** the devices, which is fine while nothing but the shell runs. In Phase 1 it's replaced by InputPlumber, or extended with grab and re-emit if InputPlumber can't be packaged for Fedora.

### ADR-004 — Session and user model — *Accepted (2026-10-22)*
- The shell/compositor runs as a dedicated system user `ruya-shell` in a logind session on seat0, started by a systemd unit (no display manager, no greeter).
- **Each profile is a real Unix user** created by `ruya-profiles` (`useradd` into the persistent `/etc`). Data isolation comes from Unix permissions.
- Apps launch in the profile user's systemd user manager (`systemd-run --user --machine=<user>@`). They connect to a per-profile Wayland socket created by the compositor and ACL'd to that user.
- Switching profiles suspends (or, if configured, stops) the previous profile's apps.
- **Not systemd-homed** for MVP: homed locks the home of logged-out users and doesn't fit 4-digit PINs. Revisit if per-profile encryption is required.
- The PIN is a profile lock, checked by `ruya-profiles` (argon2id hash, 5 attempts then exponential back-off). It is a security boundary only together with full-disk encryption (01 §3.4).

### ADR-005 — Application format — *Accepted (2026-10-22)*
**Flatpak is the only third-party format.** Console-specific metadata uses **AppStream** (localized name/description, screenshots, categories, OARS content rating, `<supports><control>gamepad</control>`), plus a small set of `x-ruya-*` custom keys (hero art, logo, background art, launch hints). Sources are Flatpak remotes: Official (ours, signed), Community (Flathub, filtered to gamepad-capable apps by default), Developer. A custom `.cbundle` archive is deferred until a concrete need appears. If one does, it will be a Flatpak bundle plus artwork, not a new runtime.

### ADR-006 — OS updates — *Accepted*
bootc images signed with cosign, served from an OCI registry, verified via `containers-policy.json`. greenboot health checks give automatic rollback. Channels are tags (`stable`, `beta`, `dev`). Details are in 01 §4.

### ADR-007 — UI toolkit — *Accepted*
Qt 6 (Fedora's version, currently ≥ 6.8) with Qt Quick and QML. Effects use `MultiEffect` and precompiled `.qsb` shaders. Not Qt 5 or `Qt5Compat`.

### ADR-008 — Project licence — *Accepted (2026-10-22, owner)*
Fully open source. Shell, image and scripts are **GPL-3.0-or-later**, which makes ADR-002 option A (QtWaylandCompositor, GPLv3) free of licensing friction. Rust services are **MIT OR Apache-2.0**, docs are CC-BY-4.0. See `LICENSE.md`.

### ADR-009 — Codecs & drivers — *Accepted (2026-10-22, owner)*
**Ship everything in one image**: RPM Fusion free + nonfree, full `ffmpeg`, `mesa-va-drivers-freeworld`, Intel `intel-media-driver`/`libva-intel-driver`, GStreamer freeworld/ugly/libav, and the **NVIDIA proprietary driver** with modules prebuilt for the image kernel (`image/build/30-codecs.sh`, `40-nvidia.sh`). A single image covers every hardware tier, so there are no `-full`/`-nvidia` variants.

Consequences:
- **Patent exposure** for H.264/HEVC/AAC etc. lands on whoever distributes the image in jurisdictions that enforce software patents. This is accepted by the owner. Mirrors and downstream redistributors should be told.
- **NVIDIA:** GPUs dropped by the current driver branch are unsupported (nouveau is blacklisted by the driver package). Secure Boot needs MOK enrollment of our module-signing cert (01 §2.3). A stable signing key from CI secrets is a Phase 6 task. Until then each build uses an ephemeral key, and its private half is deleted from the image.
- **Not included:** `libdvdcss` and AACS keys (rpmfusion-free-tainted). These are copy-protection circumvention, not codecs, and remain a separate owner decision.
- **Flatpak apps** don't see host codecs. First boot must install `org.freedesktop.Platform.ffmpeg-full`/`codecs-extra` and the matching `GL.nvidia` extension (Phase 3, `ruya-store`).

### ADR-010 — Audio ownership — *Accepted (lead, 2026-10-23)*
PipeWire runs per user, and profile apps run as other Unix users (ADR-004), so exactly one instance must own the outputs.
- **One PipeWire, in the shell's session.** PipeWire, WirePlumber and pipewire-pulse run in `ruya-shell`'s user manager, as they already do (T-121). That session is the active one on seat0, so logind gives it the sound devices. Profile users run no PipeWire of their own against hardware; their user units are masked.
- **Apps reach it through a per-profile socket**, the same way they reach the compositor (ADR-004): `ruya-session` exposes the shell's PipeWire (pulse protocol, which Flatpak's `--socket=pulseaudio` uses) to the profile's runtime directory, and access stays limited to the active profile. Designed and verified in the `ruya-session` work, not before.
- **`ruya-devices` runs as a systemd *user* service of `ruya-shell`** (`/usr/lib/systemd/user`, `ConditionUser=ruya-shell`, after `wireplumber.service`). It talks to that PipeWire directly and owns `org.ruyaos.Devices1` on the system bus; its D-Bus policy lets only `ruya-shell` own the name and only `ruya-shell` and root call it. Network and Bluetooth go through NetworkManager and BlueZ as the active session's user (polkit), so the service needs no root at all.
- Rejected: a system-wide PipeWire (unsupported upstream, and Flatpak and WirePlumber assume the per-user model); one PipeWire per profile (they would fight over the devices at every profile switch, and the shell's own sounds would need a second path).
- Cost: user units take less hardening than system units. Acceptable, because the service has exactly the shell's privileges and no more; it still gets every option a user manager supports (`NoNewPrivileges`, `RestrictAddressFamilies`, `SystemCallFilter`, ...).

## 6. Roadmap

Phases are gated by their exit criteria. Durations are rough estimates for a small team assisted by LLMs.

| Phase | Goal | Key deliverables | Exit criteria | Est. |
|---|---|---|---|---|
| **0 Foundation** | Prove the platform | Containerfile, build scripts, qcow2/ISO, cage + QML hello shell, update + rollback, greenboot | 01 §8 checklist passes in QEMU; image also boots on one real low-tier box | 3–4 wk |
| **1 Shell core** | Navigable console | Compositor spike (ADR-002), input daemon (ADR-003), home/settings skeleton, focus model, SFX, D-Bus API v1 | Fully navigable by controller; overlay over a running app; KPIs measured on low and mid tiers | 8–10 wk |
| **2 System & profiles** | Multi-user, devices | ruya-profiles, ruya-session, PIN, guest, OOBE wizard, network/Bluetooth/audio settings, USB storage | Two profiles with isolated data; first-boot setup without a keyboard; suspend/resume works | 6–8 wk |
| **3 Apps & store** | Install apps | ruya-store, remotes, store UI, updates, uninstall, permissions display | Install, run, update, roll back and remove a Flathub app and our sample app by controller | 6–8 wk |
| **4 Media** | Watch things | Jellyfin/Kodi/Moonlight/Steam Link integrated (launch, controller, audio), HW decode (ADR-009), output/refresh switching | 4K HEVC plays with HW decode on the mid tier; audio follows output changes | 4–6 wk |
| **5 Gaming** | Play things | Steam (Proton) in gamescope, RetroArch, unified library, save locations, controller config | A Steam Proton game and a RetroArch game run with a controller; saves survive OS update | 6–8 wk |
| **6 Release** | Shippable | Controller-driven installer, signing, update channels, SBOM and licence audit, factory reset, recovery | Install from USB on all three tiers, OTA update, auto-rollback demo, factory reset | 4–6 wk |
| **7 Ecosystem** | Third parties | SDK docs, app templates, official remote, review process | An external developer publishes an app to the Developer remote | ongoing |

## 7. Glossary
**bootc**: tool that boots and updates an OS from an OCI container image. **greenboot**: health checks that trigger rollback. **OOBE**: out-of-box (first-boot) experience. **OARS**: Open Age Ratings Service, the content-rating vocabulary used in AppStream. **Overlay**: the shell UI drawn over a running app (Guide menu).

### ADR-011 — `ruya-store` drives the `flatpak` CLI — *Accepted (lead, 2026-10-24)*
`ruya-store` is a pure-Rust service (like the other services, it builds on Windows for its core) that drives the `flatpak` command line (`install`, `uninstall`, `update`, `remote-ls`, `remote-add`, `info`, `list`), with machine-readable output where the CLI offers it, and reads catalogue metadata (AppStream XML/YAML from the remote's appstream directory) with a Rust XML parser. It does not link libflatpak or libappstream (GObject bindings are not pure Rust and would not build on the Windows host). Progress comes from the CLI's output, parsed in the pure core. The service runs as root with hardening (it installs system-wide on behalf of the shell), sits behind the same restrictive bus policy, and refuses unsigned remotes itself. Revisit if CLI parsing proves brittle (then libflatpak through a small helper).
