# RuyaOS — Overview, Architecture & Decisions

Status: **Draft v1** (consolidated 2026-10-22 from the three research docs; see `docs/REVIEW.md`).
Companion specs: [01-platform](01-platform.md) · [02-shell](02-shell.md) · [03-services-and-apps](03-services-and-apps.md) · [04-design-system](04-design-system.md) · [05-play-packages](05-play-packages.md) (draft)

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
- Media and streaming clients (Jellyfin, Kodi, Plex, Moonlight, Steam Link and the like) are **separate apps**, installed from the Store, and are not part of the first MVP (owner, 2026-11-06). The MVP provides the building blocks they need: launching and the Guide overlay over a running app, controller input, audio routing, hardware decode (ADR-009) and output switching. The focus is the OS, the shell UI and those building blocks.
- Gaming: Steam (Proton) and RetroArch are **separate apps** too (owner, 2026-11-06), not part of the first MVP. The MVP proves the gaming building blocks with a sample Flatpak game: launch, controller input, the Guide overlay over the running game, audio routing, and save locations that survive an OS update.

### Later / stretch
SDK and public developer programme, optical media, HDMI-CEC, HDR/VRR, cloud saves, parental controls UI, web-app runtime, custom "console bundle" format (the `.play` package: ADR-014 *Accepted, spike first; parked*, [`05-play-packages.md`](05-play-packages.md), epic T-228).

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
**Decision (owner, 2026-10-23): option A is the product direction**, on the strength of this functional result. The performance half (≥ 55 FPS with the blurred overlay over a game on the mid tier) is still to be measured on hardware (B-003); if A fails it there, fall back to **option B** (gamescope with the shell as a client). **Product path done (T-130, lead, 2026-11-02):** the image boots `ruya-shell` as the compositor on KMS, cage is gone; apps sit in the shell's app layer and the C++ `KeyRouter` keeps Guide for the shell; input devices reach the shell through a permanent `uaccess` rule (01 §2.1). Still open: the performance half (B-003), dmabuf clients, VT switching and suspend under eglfs. **Per-profile sockets (T-164):** profile apps connect to their own socket, and each client is mapped to a profile by its peer uid (ADR-023); GL clients still render in software (no `linux-dmabuf` integration in Fedora's Qt).

### ADR-003 — Controller input arbitration — *Accepted (2026-10-22); Phase 0 uses a non-grabbing stopgap*
Wayland has no gamepad protocol, so games read evdev/hidraw directly. **Recommendation:** use **InputPlumber**, already used by ChimeraOS and handheld distros. It grabs physical devices, exposes virtual controllers to games, and exposes a keyboard/D-Bus target to the shell. When the overlay opens, the shell tells it to route input to the shell. Fallback: our own `ruya-inputd` in Rust (evdev `EVIOCGRAB` + uinput + SDL mapping DB). Steam Input must be configured so it doesn't double-handle controllers (see 03 §5).

*Phase 0 stopgap:* `services/ruya-inputd` translates gamepad buttons, D-pad and left stick into navigation keys on a virtual uinput keyboard. It **doesn't grab** the devices, which is fine while nothing but the shell runs. Every pad shares that one keyboard: a key goes down when the first pad presses it and up when the last pad lets go (`KeyBoard`, a count per key), and when a pad vanishes (read error, node gone, thread unwinding) the keys it still held are released (a key another pad holds stays down) and logged (`ruya-inputd: <name> gone: <err>; released <keys the pad held>`), so a pad that dies with Down held cannot leave Down pressed (T-337). In Phase 1 it's replaced by InputPlumber, or extended with grab and re-emit if InputPlumber can't be packaged for Fedora.

### ADR-004 — Session and user model — *Accepted (2026-10-22)*
- The shell/compositor runs as a dedicated system user `ruya-shell` in a logind session on seat0, started by a systemd unit (no display manager, no greeter).
- **Each profile is a real Unix user** created by `ruya-profiles` (`useradd` into the persistent `/etc`). Data isolation comes from Unix permissions.
- Apps launch in the profile user's systemd user manager (`systemd-run --user --machine=<user>@`). They connect to a per-profile Wayland socket created by the compositor and ACL'd to that user (as built, T-164: `/run/ruya-wayland/ruya-<id>`, ADR-023).
- Switching profiles suspends (or, if configured, stops) the previous profile's apps.
- **Not systemd-homed** for MVP: homed locks the home of logged-out users and doesn't fit 4-digit PINs. Revisit if per-profile encryption is required.
- The PIN is a profile lock, checked by `ruya-profiles` (argon2id hash, 5 attempts then exponential back-off). It is a security boundary only together with full-disk encryption (01 §3.4).

### ADR-005 — Application format — *Accepted (2026-10-22)*
**Flatpak is the only third-party format.** Console-specific metadata uses **AppStream** (localized name/description, screenshots, categories, OARS content rating, `<supports><control>gamepad</control>`), plus a small set of `x-ruya-*` custom keys (hero art, logo, background art, launch hints). Sources are Flatpak remotes: Official (ours, signed), Community (Flathub, filtered to gamepad-capable apps by default), Developer. A custom `.cbundle` archive is deferred until a concrete need appears. If one does, it will be a Flatpak bundle plus artwork, not a new runtime. *See ADR-014 (Accepted, parked): the `.play` container.*

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
- **One PipeWire, in the shell's session.** PipeWire, WirePlumber and pipewire-pulse run in `ruya-shell`'s user manager, as they already do (T-121). That session is the active one on seat0, so logind gives it the sound devices. Profile users run no PipeWire of their own against hardware: drop-ins in `/usr/lib/systemd/user/` restrict `pipewire`, `pipewire-pulse` (service and socket) and `wireplumber` to `ConditionUser=ruya-shell` (T-162; before that a profile's manager started them).
- **Apps reach it through a per-profile pulse socket** (as built, T-365; the same shape as ADR-023's Wayland sockets): a second pulse server per profile, `ruya-pulse@ruya-<id>.service` in `ruya-shell`'s user manager (`pipewire -c ruya-profile-pulse.conf`, a client of the shell's PipeWire), listens on `/run/ruya-pulse/ruya-<id>/native`. The directory is 0700, owned by `ruya-shell`, with one ACL entry `user:ruya-<id>:--x`, made before the server starts, so only that profile's user can reach the socket; `/run/ruya-pulse` is 0711 (no listing). The config refuses module loading from clients (`pulse.allow-module-loading = false`: an app could otherwise load a TCP server or a pipe sink with the shell's rights) and loads no pulse.cmd helper modules. `ruya-session` starts the instance before each app of that profile (a failed start is logged; the app runs without sound) and sets `PULSE_SERVER=unix:/run/ruya-pulse/ruya-<id>/native`; `flatpak run --socket=pulseaudio` binds exactly that socket into the sandbox. Rejected: one shared pulse socket (any profile's app could connect while another plays); loading `module-native-protocol-unix` into the shell's pulse server per profile (needs pulse module loading enabled on the shell's server, and a socket made by the server cannot be given its ACL before it listens). Open: per-profile levels on app streams (B-007), stopping a deleted profile's server (unreachable once its user is gone; it ends with the shell's session).
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

Phases 4 and 5 follow the 2026-11-06 scope decisions (§2): their exit criteria are met with the building blocks (hardware decode, audio following the output, controller mapping and save locations) proven with a sample app or game, not with Plex, Steam Link, Jellyfin, Kodi, Moonlight, Steam (Proton) or RetroArch; those become separate Store apps (Phase 7 material).

## 7. Glossary
**bootc**: tool that boots and updates an OS from an OCI container image. **greenboot**: health checks that trigger rollback. **OOBE**: out-of-box (first-boot) experience. **OARS**: Open Age Ratings Service, the content-rating vocabulary used in AppStream. **Overlay**: the shell UI drawn over a running app (Guide menu).

### ADR-011 — `ruya-store` drives the `flatpak` CLI — *Accepted (lead, 2026-10-24)*
`ruya-store` is a pure-Rust service (like the other services, it builds on Windows for its core) that drives the `flatpak` command line (`install`, `uninstall`, `update`, `remote-ls`, `remote-add`, `info`, `list`), with machine-readable output where the CLI offers it, and reads catalogue metadata (AppStream XML/YAML from the remote's appstream directory) with a Rust XML parser. It does not link libflatpak or libappstream (GObject bindings are not pure Rust and would not build on the Windows host). Progress comes from the CLI's output, parsed in the pure core. The service runs as root with hardening (it installs system-wide on behalf of the shell), sits behind the same restrictive bus policy, and refuses unsigned remotes itself. Revisit if CLI parsing proves brittle (then libflatpak through a small helper).

### ADR-012 — Design language "Dreamglass" and its governance — *Accepted (owner, 2026-10-28)*
The shell's look is defined by one design system, [`04-design-system.md`](04-design-system.md): dark ground, frosted glass over a tinted, drifting backdrop, white chrome, a white focus ring with 1.08 scale, category tints as the only accent colours, a seven-step type scale and an 8 px spacing grid, all as `Theme` tokens. It formalises what Phases 1–2 built (T-102, T-117) rather than restyling it. Builders use existing tokens and components; the lead adds or changes them, updating the spec and `Theme.qml` together (§8). The typeface is Inter (OFL-1.1), bundled as a Qt resource (owner, 2026-10-28). **Amended (owner, 2026-10-28):** the main UI is gaming-first: an art-led Home with large key art and Gaussian-blurred glass chrome, and apps and games run full screen with the shell drawing nothing over them but the Guide quick menu, the volume OSD and critical toasts (02-shell §1.5, 04 §5.1); this relies on ADR-002 option A.

### ADR-013 — Icon set: Material Symbols Rounded — *Accepted (owner, 2026-11-01)*
Shell icons come from Google's **Material Symbols Rounded** (Apache-2.0), bundled as a Qt resource font holding only the glyphs the shell uses (a subset made from the upstream variable font, the source commit and checksum recorded), so Windows, the offscreen tests and the image draw the same thing. The rounded style matches the pill shapes of ADR-012. Icons are drawn by name through one component, colour from the text tokens, never an emoji or a font the host happens to have. Controller buttons (A, B, LB, …) are not icons: they are drawn as letters in circles until pad-type glyphs exist (B-006). The licence text ships in the repo and the image. Details: [`04-design-system.md`](04-design-system.md) §3.7.

### ADR-014 — `.play` packages: a self-contained container for games and apps — *Accepted (owner, 2026-11-06), conditional on the T-229 spike confirming the Flatpak route; implementation parked by the owner*
**Question.** ADR-005 makes Flatpak the only third-party format and defers a custom bundle "until a concrete need appears; if one does, a Flatpak bundle plus artwork, not a new runtime". The owner now asks for a developer-made, self-contained format (the macOS `.app`-in-a-`.dmg` idea) that can carry a game together with its Wine or Proton build or its emulator, plus artwork, video, metadata, links, a permission request and update information, and can be a folder or a `.play.zip`.

**Proposal.** Adopt `.play` as specified in [`05-play-packages.md`](05-play-packages.md), under these constraints, which keep ADR-005's spirit and the security invariants:
1. A `.play` is a **container, not a runtime**. Installing it imports it as a system Flatpak app (`play.<id>`) built by `ruya-play`; it runs only in the Flatpak sandbox, as the profile's user. The package never supplies Flatpak metadata; permissions are a closed vocabulary (05 §8). If the spike (T-229) shows this route cannot work, the fallback is the same sandbox driven by bubblewrap and this ADR is amended before anything is built.
2. **Nothing in a package runs at install time.** All parsing and unpacking happens in an unprivileged, network-less helper; a package is untrusted data.
3. **Signed.** Ed25519 signature over a file table of SHA-256 hashes; tiers `official` (our store countersigns), `developer` (key continuity, trust on first use) and `unverified` (admin's developer mode only, low and medium permissions). Revocation list. Updates must come from the same key; the Store is the update channel for Store packages, an opt-in signed feed for sideloaded ones.
4. **System runners** (Wine first) are Flatpak extensions published on the `ruyaos` remote and updated independently of the OS; a package may bundle its own runner, use the system one, or take the newer of the two.
5. Flatpak and Flathub remain the normal way to distribute apps. `.play` is for self-contained games, Windows games under Wine/Proton, emulated titles and developer testing.

**Consequences.** New services and tools: `ruya-play` (import, verify, feeds), `ruya-pack` (developer CLI), a launcher and runner extensions; a shell "install from USB" flow and a package page; Xwayland or Wine's Wayland driver becomes a prerequisite for Windows games (no Xwayland today). Maintenance cost: the Play platform extensions, the runner builds, the review process for the Official tier. RuyaOS ships only Wine as a system runner; emulators, Proton/Steam runtime, firmware and disc images are supplied by packagers and carry no distribution duty for RuyaOS (owner, 2026-11-06; 05 §14). If RuyaOS hosts packages itself, that remote's acceptance rules are a separate later decision.
**Alternatives rejected.** (a) Flatpak only, with Heroic/Lutris for Windows games (no single-file distribution, no console art/permission model, per-launcher prefixes outside our control). (b) A new runtime and sandbox (an ADR-005 non-goal, security cost). (c) AppImage-style run-in-place (no sandbox, no verification before use, no deduplication).
**Status of the rest.** Owner, 2026-11-06: accepted; RuyaOS provides Wine as the only system runner and the image preinstalls it; the epic (T-228) is **parked** (stays `blocked`) behind the current visual-polish lanes and T-164, and no `.play` code is written yet. Spec 05 describes the design, not the code.

### ADR-015 — The app platform: a Flatpak runtime extension `org.ruyaos.Platform` with the RuyaKit QML module — *Accepted (owner, 2026-11-08)*
**Question.** How does a first-party or third-party app use the console's own components (design tokens, `FocusGlide`, `GlassPill`, cards, lists, dialogs, the on-screen-keyboard hook, controller focus handling) and the Platform API client bindings (ADR-022) without copying the shell? Options were (A) a Flatpak runtime extension, (B) a module every app bundles, (C) a full custom runtime (T-250).

**Decision (owner, 2026-11-08).** **A: a Flatpak runtime extension `org.ruyaos.Platform`** that carries the **RuyaKit** QML module (T-251), the fonts, icons and sounds the components need, the `Platform1` client bindings and the stability tags, on top of the Qt base runtime apps already use. It is **versioned separately from the shell** (its own release train and API version, published on the `ruyaos` remote, updated through `ruya-store`). **Not a module per app** (B: larger apps, no shared fixes), and no custom runtime (C) unless the spike shows A cannot work. Only the public surface goes into it (nothing shell-private: no `Session`, `Store` or `KeyRouter` singleton).

**Questions the spike (T-250) still has to answer with numbers, in its Outcome and as amendments to this entry:** which base runtime and Qt version the extension builds against, and how it stays compatible with the Qt of the shell (Fedora's Qt, 6.8 or newer); the size of the extension and of an app that uses it; the update flow and the compatibility rule between an app, the extension and the console's API level (ADR-022, `RUYA_API_LEVEL`); how a theme change (T-209) and the quality tier reach an app that runs sandboxed as a profile user (a portal, a settings file or an environment variable); how focus, the Guide overlay and the on-screen keyboard cooperate with an app window; the extraction audit (what can move into RuyaKit without forking and what stays shell-only: compositor, Guide overlay, Settings panes, wizard); the start time of a RuyaKit app in the VM. If the spike shows the extension cannot work, the builder writes a *Proposed* amendment and stops for the lead; the owner decides, not the builder.

**Consequences.** T-250 becomes the implementation spike (extension skeleton, one themed window with a controller-focused button, a theme switch seen from the app), T-251 builds RuyaKit as the extension's module, T-252 the template and publish recipe; the app-facing capabilities of ADR-022 reach apps through the extension's client bindings and the `Platform1` door (T-352).

### ADR-016 — A web browser: not in the first set of first-party apps — *Accepted (owner, 2026-11-08)*
**Question.** Should the first-party apps (epic T-248) include a web browser, and on which engine (Qt WebEngine, a wrapped existing browser, none)? A browser is the largest and riskiest app: a large engine, constant security updates, untrusted code.

**Decision (owner, 2026-11-08).** **No browser first.** The first-party apps come in this order: picture viewer, weather, media player, file manager, Jellyfin client (the emulator frontend, T-259, stays in its place after them). A browser gets **its own decision later**, as a new Proposed ADR with the engine options, who owns security updates and spike numbers; until then nothing browser-related is built. "Web app" shortcuts stay deferred (§2).

**Consequences.** T-258 is parked by the owner (it keeps its text, options and criteria for the day the decision is reopened); the T-248 table loses its browser step; no browser engine in RuyaKit or the extension.

### ADR-017 — Multiple controllers and local players — *Accepted (owner, 2026-11-07)*
**Question.** What happens when a second controller connects: which pad drives the shell, who "owns" a pad, how a second person (a profile or a guest) plays in the same session. Nothing exists today: `ruya-inputd` turns every pad into the same navigation keys (ADR-003), and there is no owner or slot concept.

**Architecture fact.** ADR-004: one active profile session at a time, apps run as that profile's Unix user. Other people are therefore **local players inside the session**, never parallel sessions.

**Model.** A *controller registry* (per pad: id = BlueZ address or USB path, family, nickname, default owner profile or none) and *player slots* 1..N per session. Slot 1 is the session owner's pad. Assignment = slot → a profile or Guest; it lasts for the session (a Guest assignment is temporary and is wiped at session end, at "leave" or after idle). A pad that reconnects within 60 s gets its slot back.

**Decisions (owner, 2026-11-07, "apply your recommendations").**
1. **Shell navigation:** the slot 1 pad anywhere; **any** pad at the login screen and on the "Who's playing?" dialog; other pads navigate only inside apps.
2. **What a non-owner player's profile means:** saves stay the session owner's per-app data. An assigned profile only **attributes** achievements (T-246) and play time (T-247). The **strictest age limit** of owner and players applies at launch (T-211). Guest = no attribution.
3. **No PIN** to assign a pad to a profile for play (no data access is gained). Admin features never come from a non-slot-1 pad.

**Consequences.** New contract (registry, `Assign`/`Release`, signals), persistence root-only under `/var/lib`, a "Who's playing?" dialog and player chips, and, for apps to see slots in order, ordered virtual gamepads per slot with the physical pads hidden (needs the virtual-device layer of T-217/B-006). Epic and tasks: T-263 (spec), T-264 (services), T-265 (shell), T-266 (virtual pads), T-267 (default owner at login), T-268 (guest player).

### ADR-018 — Epic Games Store on RuyaOS — *Proposed (2026-11-07), owner decision needed*
**Question.** The owner asked for Epic Games Store integration the way Heroic does it. Heroic's Epic support is Legendary, an open-source (GPL-3.0) command-line client that uses Epic's unofficial web and launcher APIs; Epic offers no sanctioned third-party launcher API and may change or block it. Games run as Windows titles through Wine/Proton (no anti-cheat titles).

**Options.** (a) **A first-party RuyaOS app** (Store-installed, sandboxed, built on RuyaKit, T-251) that drives Legendary and launches games through the system Wine runner of ADR-014; the OS image itself ships no Epic code, like Steam and RetroArch (§2). (b) Point players to the unmodified Heroic Flatpak from Flathub (no controller-first UI; costs nothing; may not suit the shell's input model). (c) Not at all.

**Recommendation.** (a), after the `.play`/Wine spike (T-229) and the runner pack (T-244), as a Store app with its own release cycle, so a break in Epic's API never touches the OS. **Owner-level because** it depends on a third party's unofficial API and terms of service (legal), uses its trademark in the UI (use the neutral label "Epic Games" only in text; no logo until decided), and adds GPL-3.0 components (source offer). Until decided, T-270 stays `blocked` and no Epic code is written.

### ADR-019 — Multitasking: one foreground app, frozen background apps, politely closed under pressure — *Accepted (owner, 2026-11-08)*
**Question.** The owner wants iOS/Xbox/PlayStation-style switching between open apps and games, a smooth shell, and background apps closed when a game needs the memory. Today one app can be in front and the others "keep running until closed (memory limits: later)" (02 §1.5); T-147 plans a plain "Switch to" list, T-165 freezes a whole profile's apps on a profile switch, T-201 protects the shell from OOM.

**Proposal.** (1) One **foreground** app; every other open app is **frozen** with the cgroup freezer after a short grace (no CPU, memory kept, resumes in a frame), unless it declares a background reason (`X-Ruya-Background=audio|download`) that currently holds. (2) The compositor keeps a small **snapshot** of each app's last frame for the switcher and tells apps when they are hidden or visible (`xdg_toplevel` suspended, 03 §4.6). (3) Under memory pressure the **least recently used background app is closed** (SIGTERM, 5 s to save, then kill) with a toast and a relaunch card; never the shell, never the foreground app; the foreground game gets the weights, the background `MemoryHigh`. (4) At most N open apps (default 4, by RAM). (5) **Switcher** = a row of cards in the Guide quick menu; **Guide double-press** jumps to the previous app; hold Guide stays the power menu. (6) The spike T-274 measures freezing on the Dell before anything depends on it; games that break under freeze fall back to cooperative pause or save-and-close.

**Decided (owner, 2026-11-08):** (1) the gesture: **Guide short press = the quick menu with the switcher row, Guide double press = the previous app, Guide hold = the power menu**; (2) **one foreground app, every other app frozen** (cgroup freezer), **least recently used closed under memory pressure with a toast**; (3) **background apps opt in** (`X-Ruya-Background`, audio or download, only while the reason holds); (4) **a frozen online game warns once in the switcher** (it may disconnect). The technical parts (grace times, N, the memory policy) stay the lead's after the spike T-274, which measures freezing before anything depends on it.

**Consequences.** New contract surface in Session1 (states, `Switch`, `SetBackgroundReason`), compositor snapshots, a policy in `ruya-session`, developer-guide rules. Epic T-273, tasks T-274..T-279; everything is gated by T-164.

### ADR-020 — The game data hub: one OS API for ROM folders, save and capture paths, and now-playing metadata — *Accepted (owner, 2026-11-08); behind `Platform1` per ADR-022*
**Question.** The owner wants RuyaOS to be a hub between game apps: an emulator asks the OS where the SNES ROMs are and where saves, states, configs, screenshots and recordings go; the OS learns from the app what is played (game, emulator, settings, who) and exposes it to the shell and to permitted apps. Today each app invents its own folders (03 §4.5a only recommends a layout), the emulator frontend would scan on its own (T-259), and nothing knows what is running beyond the app id.

**Proposal.** (1) A system service `ruya-hub` (`org.ruyaos.Hub1`) answers per profile (the caller's identity decides, never an argument). **It is an internal service (tier A of ADR-022): no sandbox reaches it directly. Its app-facing calls are an interface of `Platform1` (T-352), which identifies the app and profile, checks the player's permission, rate-limits and forwards; the shell and root reach `Hub1` itself.** The calls: `RomRoots(system)`, `Paths(kind, game)` (kinds saves, states, config, screenshots, recordings, mods), `Identify(file)` (stable content-based game id), `Players()` (ADR-017). (2) System ids follow libretro/No-Intro naming and live in a data file. (3) Apps **push** now-playing (`Report`: game, system, emulator, core, settings summary, state) with size and rate caps; the OS keeps the latest per running instance and shows it in the Library and Activity pages; the play ledger (T-247) keys time to the game id. (4) **Captures belong to the compositor**: screenshots (and, if the Dell budget allows, recordings and a "clip the last 30 s" buffer) are taken by the shell for any app and stored with metadata in the profile's Captures library. (5) Other apps read now-playing and captures only with a per-app permission, off by default, asked on first use, revocable in Settings > Privacy (T-220). (6) RuyaOS ships no ROMs, BIOS or emulators and scans removable media only after an explicit player action.

**Decided (owner, 2026-11-08):** (1) other apps may read now-playing and captures, **off by default, asked per app on first use, revocable in Settings > Privacy** (the per-app permission table of `Platform1`, T-220); (2) a **shared read-only ROM folder** visible to all profiles, besides the per-profile folders; (3) **captures stay local in v1** (they never leave the console); (4) **saves and states stay on the console** (a pulled drive must never lose or corrupt a save); drives hold ROMs, captures and backups. The technical parts are the lead's after the spike T-303.

**Consequences.** A new internal service, hub policy and unit (shell and root only), the `Platform1` interface in front of it (T-352), a compositor capture path, Library changes, a developer-guide chapter and a sample. Epic T-302, tasks T-303..T-308.

### ADR-021 — Retro achievements: link a RetroAchievements account per profile and show its unlocks, without the OS running the achievement logic — *Accepted (2026-11-08, owner)*
**Question.** The owner wants achievement support for retro games, next to the retro ROM support (hub, ADR-020) and the native achievements (T-246). RetroAchievements (retroachievements.org) is the established community service: sets are tied to a ROM hash and emulators unlock through the open `rcheevos` runtime. Should the console run that logic itself, leave it entirely to each emulator, or sit in between?

**Proposal.** The emulator keeps doing the detection and the reporting (it has the memory and the rules, including hardcore mode). The OS adds what an OS can: one account link per profile (token only, root-only store, password never kept), a per-app permission that hands the credentials to an opted-in emulator, a cached read of the player's progress (offline-first) shown in the Library, on the game page and in a Retro tab next to the native achievements, and the console's own unlock toast fed by the hub's `Report` event or, as a fallback, a slow poll. Off by default for child profiles. No ROM, set or site image is shipped; badge images are fetched at run time and cached per profile. Epic T-314, tasks T-315..T-318.

**Decided (owner, 2026-11-08):** (1) yes, the console talks to retroachievements.org for the player, and the OS (not only the emulator) shows the achievements in its own UI; it connects only after the player links an account, nothing before. (2) yes, the RetroAchievements name and badge images may be used in the UI, with the site credited; images are fetched at run time and cached per profile, none is bundled (a courtesy note to the site operators is welcome but not a gate). (3) token storage is the lead's call: root-only per profile, not in backups unless the player ticks it, deleted on unlink and with the profile. (4) child profiles off by default. The facts about the site (terms, rate limits, hashing, `rcheevos` licence) stay unverified until the spike T-315.

**Consequences.** A new service and bus policy, `Hub1` additions, a Settings pane, Library and profile changes, a developer-guide note for emulator authors. Depends on the hub (T-302..T-304, T-306, T-307) and the native achievements (T-246).


### ADR-022 — The public developer surface: three tiers, one narrow door for apps, versioned and documented as part of every task — *Accepted (owner, 2026-11-08)*
**Question.** Which parts of RuyaOS may apps (third-party and our own) rely on, how do they reach them, and who makes sure each one is documented, tested and stable? Today every D-Bus service answers only the shell and root (a security invariant), so nothing is callable from a sandbox. But tasks now add app-facing APIs one by one, each with its own bus name, bridge and documentation plan: notifications (T-245), achievements (T-246), now-playing and paths (ADR-020, T-304/T-306), lifecycle (T-279), player slots (ADR-017, T-266). Without a charter the surface grows by accident, and a private service becomes public by a bus-policy edit.

**Proposal.** (1) **Three tiers.** *A, shell-private:* Profiles, Store, Update, Devices admin, Telemetry configuration; never exposed, the bus policy stays "shell and root only". *B, the Platform API:* a new narrow service `ruya-platform` (`org.ruyaos.Platform1`, system bus, one `--system-talk-name` per app) is the only door a sandboxed app has; it identifies the caller (Flatpak app id, profile), checks a per-app permission table the player controls in Settings > Privacy (T-220), rate-limits, sanitises, answers per profile and forwards to the internal services, which stay private. *C, data-only formats* (no code, safest): the save-data layout (03 §4.5a), AppStream `x-ruya-*` keys, `.play` packages, sound/theme/wallpaper packs, icon conventions. (2) **The candidate Tier B list, approved once** (anything else needs a new ADR line): lifecycle (suspend/resume/stop, "save now"), achievements, play statistics and rich presence/now-playing, notifications, controller input extras (player slots, rumble, battery), text input (on-screen keyboard), display information (read-only), theme accent (read-only), age-rating and parental respect (read-only flag), a portal-style storage picker. **Never public:** profiles, PINs and admin, update, install/uninstall, system settings writes, telemetry. (3) **Process.** A task header field `Developer surface: none | internal | public-API | public-format` set at planning; a public task's Definition of done adds a documented XML contract with a stability tag, a developer-guide paragraph, a runnable sample, mock support for off-device testing and a conformance test; a read-only `ruya-api-reviewer` agent checks every diff that touches a public surface; a `ruya-devdocs-auditor` agent follows the guide as a newcomer before each release. (4) **Versioning.** `RUYA_API_LEVEL` in os-release; apps declare the minimum in AppStream; the Store hides apps the console cannot serve; everything is *experimental* (no promise) until the first release, then additions only within a level and a two-level deprecation window. (5) **Dogfooding.** A first-party app may use only the public surface.

**Options.** (a) The charter above (recommended). (b) One bus name per feature (`Hub1`, `Achievements1`, ...) reachable from the sandbox: least new code, but Flatpak grants a bus name all-or-nothing, so the per-app permissions of T-220 cannot be enforced by the platform, every service must be hardened against hostile callers, and identity, rate limits and versioning are done N times. (c) Nothing public in v1: apps get Wayland, PipeWire and evdev only; no achievements, notifications or hub, so no "console" features for third parties.

**Decided (owner, 2026-11-08):** option (a) **approved as drafted**: the Tier B capability list is approved (a new capability needs a new ADR line first), the "never public" list stays, and stability promises start only at the first release. The design of the proxy and the level numbers are the lead's. **Risk to prove first (T-352, step one of that task):** that a caller behind `xdg-dbus-proxy` on the system bus can be mapped to its Flatpak app id the way the session-bus portals do it; if not, the per-app permission falls back to a per-app session-bus portal in front of the same service.

**Consequences.** New service and bus policy (T-352); mock and sample harness for developers (T-353); API level (T-351); lint (T-350); the app-facing parts of T-245, T-246, T-279, T-304, T-306 and T-266 are re-seated behind `Platform1`, and `Hub1` becomes an internal service reached through it; ADR-015 (Accepted with this ADR, owner, 2026-11-08) puts the client bindings in the `org.ruyaos.Platform` runtime extension. Detail and the task audit: [`docs/developers/api-surface.md`](../developers/api-surface.md).

### ADR-023 — Per-profile Wayland sockets: made by the compositor, one per profile user, closed by mode and ACL; each client mapped to a profile by its peer uid — *Accepted (lead, 2026-11-09, T-164)*
**Question.** An app runs as its profile's Unix user (ADR-004), but the compositor (`ruya-shell`) listened only on `ruya-0` in its own 0700 runtime directory, so a profile's app found no display (Dell, 2026-11-08: SuperTuxKart ended with "No available video device"). Where does a profile's socket live, who makes it, how does the sandbox see it, and how does the compositor know whose window a client is?

**Decision.**
- **The compositor makes the sockets** (`shell/compositor/ProfileSockets`): for every profile it knows, a listening socket `/run/ruya-wayland/ruya-<id>`, owned by `ruya-shell`, mode 0600 plus one POSIX ACL entry `user:ruya-<id>:rw-`, so only that user can connect (connecting needs write permission). The directory is the compositor unit's `RuntimeDirectory` (0711: a profile user can open its own socket by name but cannot list the others), emptied at every start and stop of the shell. Each socket is bound in a private 0700 staging directory, given its mode and ACL there, then renamed into place, so no other user can connect at any moment. The fd goes to `QWaylandCompositor::addSocketDescriptor`. libwayland cannot drop a listening socket, so the socket of a deleted profile is unlinked (unreachable) and its fd stays idle until the shell restarts. `ruya-0` stays for the shell's own clients (VM test clients).
- **The spawner points the app at it:** `ruya-session` sets `WAYLAND_DISPLAY=/run/ruya-wayland/ruya-<id>` (an absolute path) for every app unit, and `SDL_VIDEODRIVER=wayland` (there is no X server). `flatpak run --socket=wayland` binds exactly that one socket into the sandbox as `$XDG_RUNTIME_DIR/wayland-0` and sets `WAYLAND_DISPLAY=wayland-0`; the sandbox never sees `/run/ruya-wayland` and so has no path to another profile's socket. An app without the `wayland` socket permission (X11-only) gets no display: there is no Xwayland.
- **Whose window it is** is decided per client by its peer uid (`WaylandClient.userId`, `AppGate.verdict`, C++ in the shell, tested on every host): the signed-in profile's user is that profile's; the shell's own user is the shell's (shown to whoever is signed in); everyone else (another profile, root, any other uid), and every client but the shell's while nobody is signed in, is closed when it makes its first surface, before anything is drawn. `Shell.addApp(item, profile)` shows a window only to its own profile and hides every window while nobody is signed in (the picker and the wizard are never covered); a hidden window gets no focus and no keys. T-165 decides what a profile switch does to the hidden apps.
- **Input for profile apps (minimal):** apps get keyboard and pointer events through the compositor (`wl_seat`), which already carries what `ruya-inputd` makes of the pads (arrows, Return, Escape, ...). Profile users get **no** access to `/dev/input/event*` (the `uaccess` ACL stays with the seat session, the shell's), so a game cannot read a pad directly yet; real pad access for games (and the double input of B-006 once they can) is T-217/T-266's.
- **GL clients:** Fedora's `qt6-qtwayland` ships only the `wayland-egl` client-buffer integration (no `linux-dmabuf-unstable-v1` plugin), and `wayland-egl` needs `EGL_WL_bind_wayland_display`, which the image's Mesa does not offer (the shell logs its absence on the Dell and in the VM). On the Dell (T-355) STK through the shell rendered on llvmpipe at 563 % CPU. **T-358 (Accepted (lead, 2026-11-09)):** the image builds Qt's own `linux-dmabuf-unstable-v1` compositor plugin from the source RPM of the installed qt6-qtwayland (stage `qt-dmabuf` in `image/Containerfile`) with our patch `image/qt/0001-linux-dmabuf-v4-feedback.patch`: protocol v4 with default and surface feedback (`main_device` = the EGL device's render node, one tranche); `ruya-compositor@.service` sets `QT_WAYLAND_CLIENT_BUFFER_INTEGRATION=linux-dmabuf-unstable-v1;wayland-egl`. On the Dell STK then renders on the UHD 630 at about 15 % CPU, 1080p60, with the Guide overlay over it. The plugin uses private Qt API: the build refuses an image whose Qt differs from the one it was built against. Open: explicit sync (NVIDIA proprietary), `external_only` modifiers in the tranche, multi-GPU, direct scanout (B-003). Worth upstreaming.

**Rejected.** (a) *`ruya-session` (root) makes the socket in the profile's runtime directory and hands the fd to the shell over `Session1`* (the planner's first idea): the root service would need `CAP_CHOWN`/`CAP_DAC_OVERRIDE` and a hole in `ProtectHome=yes` (which hides `/run/user`), it would put fds on the system bus, and the socket's life would follow the service while its listener (libwayland cannot remove one) follows the compositor; a restart of either leaves the other with dead sockets. Same tightness, more privilege and more moving parts. (b) *One shared socket for all profile users, filtered by peer uid only:* any profile's process could connect while another profile plays and talk to the compositor's globals before it is refused; the per-user socket keeps them out at `connect()`. (c) *A socket in each profile's `$XDG_RUNTIME_DIR` made by the profile's own user manager (a socket unit):* the listener would be a process of the profile, not the compositor; only a proxy could bridge it. (d) *`--filesystem=/run/ruya-wayland` for the sandbox:* would show every profile's socket path to every app.

**Consequences.** `ruya-compositor@.service` gets `RuntimeDirectory=ruya-wayland` (0711). The display an app gets (an absolute `WAYLAND_DISPLAY`, `wayland-0` inside Flatpak, `SDL_VIDEODRIVER=wayland`) is something apps rely on: *experimental* until the first release (ADR-022). The same "path into the profile" question for `ruya-library` (Steam libraries in the profile's home, `ProtectHome`) is answered the same way, by running the per-profile part as the profile: see `03` §4.1.

### ADR-024 — Ruya Input: one input service owns the pads; apps get virtual devices of their profile only; the shell keeps a path that cannot be taken away — *Accepted (lead, 2026-11-09; target set by the owner's requirements, `06-input-requirements.md`)*
**Question.** The owner's requirements for the input subsystem (`06-input-requirements.md`: device discovery and capabilities, normalisation, mapping, layers, routing and ownership modes, virtual pads/keyboard/mouse, haptics, gyro and touchpad, profiles, an SDK, settings UI, Quick Resume, community profiles) meet a console where games run as the profile's Unix user and see **no** controller today: the physical pads' nodes carry an ACL for `ruya-shell` only (Dell, 2026-11-09: SuperTuxKart's Controls list shows the keyboard alone), and `ruya-inputd` (ADR-003's stopgap) turns every pad into navigation keys that reach the focused game through `wl_seat`. How do the requirements fit ADR-003, ADR-004, ADR-017, ADR-022 and ADR-023, and in which order are they built?

**Decision.**
- **One input service** owns the physical controllers (discovery, identity, capabilities, normalisation, mapping, routing, virtual-device lifecycle) and is the only reader of physical pads apart from the shell's emergency path. Which engine it is stays ADR-003's question and is answered by the spike **T-366** with evidence: InputPlumber (not packaged in Fedora 44, so built in the image; GPL-3.0; runs as root) or our `ruya-inputd` grown into it (ADR-003's named fallback). Either way the processing runs with the least privilege the spike shows to be enough (the requirement "not the whole engine as root").
- **Apps see only virtual devices of their own profile.** Physical nodes keep their shell-only ACL (unchanged from ADR-023). The service creates the virtual devices (uinput: an Xbox-style pad per player, later keyboard and mouse) and gives each node one ACL entry for the signed-in profile's user (`ruya-<id>`), removed at lock and switch, the same "closed by ACL, one user" rule as ADR-023's sockets and ADR-010's pulse sockets. A Flatpak game needs `--device=input` (or `all`) to see them.
- **Routing follows the focus.** While an app has the focus the service sends it pad input only through its virtual devices and stops the navigation keys (no double input); Guide always goes to the shell (the compositor's `KeyRouter`), and the shell's overlays take the pad back. If the service dies, the shell must still navigate (a fallback reader for the shell, decided in T-366).
- **Ownership modes** (requirements §6): *Ruya-managed* (default), *direct passthrough* and *Steam-managed* (the profile's user gets the physical nodes and hidraw for that run, no virtual pad from us) are per-app settings stored by the service, never by editing Steam's files.
- **Profiles** (requirements §9) are versioned JSON with a schema, validated on load and import, inheriting game → platform → global → built-in; per controller identity and per console profile. No scripts in profiles; macros are data with limits.
- **Apps reach the semantic API only through `Platform1`** (ADR-022): actions, glyphs, haptics requests. The raw evdev surface (virtual pads) is public too and documented in `docs/developers/controller-input.md`.
- **Order** (each a task, smallest useful slice first): T-366 spike, engine decision and `06-input.md` (design: model, schema v1, `Input1` contract draft) → T-367 *a game sees the pad* (virtual pad per pad, profile ACL, focus routing) → T-368 controllers pane, capabilities and button test → T-369 mapping v1 (layout swap, dead zones, curves, global profiles, import/export) → T-370 game and platform profiles → T-371 ownership modes (passthrough, Steam) → T-372 keyboard/mouse output, layers, chords, shortcuts → T-373 gyro, touchpad, rumble/haptics back to the pad → T-374 semantic actions and glyphs for apps. ADR-017's slots (T-264, T-266) use T-367's layer. T-217 is split into these tasks.

**Rejected.** (a) *Give the profile user the physical pads* (simplest, and what a desktop does): no remapping, double input with the navigation keys, the shell's Guide path depends on the game, and a pad of player 2 would be readable by whoever is signed in. (b) *Building the requirements as one subsystem in one go:* the document itself asks for small stages; the first useful result is a game that sees a pad.

**Consequences.** New contract `org.ruyaos.Input1` (T-366 drafts, T-367/T-368 build), a udev rule and an ACL owner for virtual nodes, the shell's focus reaches the input service, B-006 is replaced by these tasks. Owner-level and later: a community profile repository (hosting, moderation, publishing), glyph licences (T-199), anything that needs Sony/Microsoft/Nintendo terms (adaptive triggers through hidraw are technical, no terms question known).

### ADR-025 — Windows runners: a set of them, GE-Proton preinstalled and the default — *Accepted (owner, 2026-11-09: "we should ship proton ge default", "also wine, Wine-GE etc."), details open (lead, 2026-11-09)*
**Question.** ADR-014 (D3, owner 2026-11-06) made Wine the only system runner and shipped no Proton or Steam runtime. The owner now wants GE-Proton (the community Proton build with extra game fixes and media support) shipped and used by default.

**Decision (direction, owner).** The image preinstalls **GE-Proton** and it is the default runner for Windows games: `.play` packages with `runner: proton-ge` or `source: system` of the Windows kind, first-party launchers (the Epic app of ADR-018 if accepted) and, when the player installs Steam, Steam's default compatibility tool. It updates through the Store, independently of the OS, pinned to tested releases. This amends ADR-014 D3 ("only Wine"). **More runners, the player's choice (owner):** plain Wine (stable and staging), Wine-GE, Valve's Proton as UMU-Proton and other open builds are offered as further runner extensions in the Store, installed on demand, one branch per major; a game's Compatibility setting picks the runner and version per game (`05` §6.2's per-game override, now for every Windows game). Only GE-Proton is preinstalled. Wine-GE's upstream stopped in 2024 (its author points to GE-Proton with umu): T-381 confirms, and if so it is offered only as a frozen legacy branch for games that need it.

**Lead decisions inside it.**
- **Form:** a Flatpak extension, one branch per GE-Proton major (`org.ruyaos.Runner.GEProton//<major>`, name fixed by T-381), built from the upstream release tarball with a pinned checksum, never downloaded at run time by the OS. It runs through **umu-launcher** and the Steam Linux Runtime the way Heroic and Lutris run it; the spike (T-381) decides whether those come as extensions too.
- **Display:** Wine's Wayland driver if GE-Proton's works on the per-profile socket (ADR-023); otherwise Xwayland in the compositor becomes its own task. No X server is added silently.
- **Developer surface (ADR-022):** **no D-Bus call** runs a Windows program for an app (that would launch code outside the caller's sandbox). An app or package *uses* the runner by declaring the extension in its own Flatpak manifest and reading its `runner.json`; that is a **tier-C data format** (extension name, branch, `runner.json`, the umu entry), experimental until the first release, documented in `docs/developers/` with a sample (T-384). Which runner and version the shell shows (About, a game's Compatibility screen) is internal (tier A).

**Open, owner-level (T-381 brings the facts).** (1) Licences: GE-Proton bundles Wine and vkd3d-proton (LGPL: a source offer for what we ship), DXVK (zlib) and more; the full list and the notice in About. (2) **Codecs:** GE-Proton ships media playback pieces (GStreamer with FFmpeg/libav for H.264, AAC and others) that Fedora leaves out for patent reasons; ship as is, strip them, or ship them as an optional extension. (3) The Steam default: Steam is a separate Store app (§2); setting its default tool edits Steam's own config once at install.

**Consequences.** Tasks T-381 (spike, lead), T-382 (preinstall and update), T-383 (Steam default), T-384 (developer chapter and sample), T-385 (the runner catalogue and per-game choice). The `.play` epic (T-228) stays parked; T-244 (the Wine runner pack) becomes part of T-385's catalogue.
