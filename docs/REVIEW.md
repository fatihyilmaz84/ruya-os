# Spec Review — RuyaOS research documents

Reviewed 2026-10-22. Sources (now moved to `docs/archive/research/`):

| File | What it is |
|---|---|
| `deep-research-project.md` | Full architecture + roadmap (broadest) |
| `deep-research-report-env.md` | Reply to an external "review" (not in repo) — build/test workflow |
| `deep-research-report-ui.md` | UI/UX, performance, KPIs, second roadmap |

They have been consolidated into `docs/specs/`:

| Spec | Covers |
|---|---|
| [00-overview.md](specs/00-overview.md) | Vision, scope/MVP, architecture, decision log (ADRs), roadmap |
| [01-platform.md](specs/01-platform.md) | OS image, session startup, updates/recovery, installer, dev workflow, testing, CI |
| [02-shell.md](specs/02-shell.md) | Shell UI, graphics, input/focus, audio, assets, performance KPIs |
| [03-services-and-apps.md](specs/03-services-and-apps.md) | Profiles/security, devices, apps & store, media, gaming |

---

## 1. Duplication

Roughly 40% of the content shows up two or three times, and some of the copies disagree.

| Topic | project | env | ui | Notes |
|---|:-:|:-:|:-:|---|
| Fedora bootc base + immutability | ✓ | ✓ | ✓ | Consistent apart from bootc internals (see §3) |
| Compositor comparison | ✓ (table) | ✓ (prose) | ✓ (table) | Two tables, and they contradict each other on wlroots |
| Phase 0 POC | ✓ | ✓ | ✓ | Three versions with different exit criteria |
| Phased roadmap | ✓ (P0–P7) | — | ✓ (P0–P5) | **Phase order differs** (see §2) |
| Packaging / `.cbundle` | ✓ | ✓ | ✓ | Three different formats proposed |
| Animation / QML techniques | ✓ | — | ✓ | ui is a superset |
| Sound design / PipeWire | ✓ | ✓ | ✓ | ui is a superset |
| Controller / focus model | ✓ | — | ✓ | ui is a superset |
| Testing matrix | ✓ | ✓ | ✓ | Merged into 01-platform §7 |
| Mermaid architecture diagram | ✓ | — | ✓ | Two diagrams that disagree on data flow |

## 2. Contradictions between the documents

1. **Roadmap order.** project: P3 Media → P4 Packaging → P5 Gaming. ui: P3 Packaging/SDK → P4 Media → P5 Gaming. *Resolution:* packaging comes first, because media and gaming clients ship as apps.
2. **App format.** project: "lean toward Flatpak", but also a `.cbundle` that is either imported into Flatpak *or* run with Podman, and also Qt AM `.ppk`. env: `.cbundle` wraps an OCI image or a Flatpak ref. ui: `.cbundle` is an OCI archive managed by a custom Rust package service. *Resolution:* Flatpak only, plus AppStream metadata (ADR-005).
3. **Two different manifest schemas** in project (`launch/cmd` vs `applications[]/executable`).
4. **Third-party runtime.** project's summary says "WebView or Qt Application Manager", while its body says Flatpak.
5. **Credential storage.** systemd-homed, then "PAM with libcrypt", then "document `/etc/shadow` or sssd". Each is a different mechanism.
6. **wlroots.** project calls it "existing (sway)". ui says it "requires writing a custom compositor from scratch".
7. **Phase 0 status.** The Gantt chart marks Phase 0 `done` (2026-10-15 + 20 days). There is no code, and that end date (2026-11-04) is still in the future.
8. **60 FPS in Phase 0.** project says to verify 60 FPS "on hardware" in Phase 0, but Phase 0 runs only in QEMU, where GPU performance isn't representative.
9. **Data volume.** project says user data lives "on a separate volume", and later says "with bootc usually everything is on one root partition".

## 3. Wrong or doubtful technical assumptions

Severity: 🔴 would break something or lose data · 🟠 wrong, would waste work · 🟡 inaccurate or outdated

| # | Sev | Claim (source) | Reality |
|---|---|---|---|
| 1 | 🔴 | `podman run … bootc install to-disk /dev/vda` "writes the image to /dev/vda, which QEMU will use" (env) | Inside a Podman Machine, `/dev/vda` is **the Podman Machine's own disk**, so this would wipe the build VM. Use `bootc install to-disk --via-loopback /output/disk.raw` or `bootc-image-builder --type qcow2`. |
| 2 | 🔴 | "Use **libinput** for controllers" (project) | libinput doesn't handle gamepads or joysticks. Use evdev/hidraw via SDL3 or InputPlumber. |
| 3 | 🔴 | Gamepads navigate the shell and games at the same time, with no arbitration (all) | Wayland has **no gamepad protocol**. Games read evdev/hidraw directly, so a game keeps receiving input while the shell's overlay is open. That needs a grab-and-re-emit input daemon (InputPlumber, or Steam Input's approach). This was missing entirely. |
| 4 | 🔴 | "Update failures automatically revert to the old image" (project) | bootc has **no automatic rollback** by itself. It needs greenboot (health checks plus a boot counter). |
| 5 | 🟠 | "Qt Gamepad" as a controller option (ui) | The Qt Gamepad module was **not ported to Qt 6**. |
| 6 | 🟠 | Inline GLSL in `ShaderEffect { fragmentShader: "/* GLSL */" }` (project), `FastBlur` / QtGraphicalEffects (ui) | Qt 6 needs shaders **precompiled to `.qsb`** with `qsb`. QtGraphicalEffects only exists as `Qt5Compat`. Use **`MultiEffect`** (Qt ≥ 6.5) for blur. The example also blurs a flat translucent rectangle, which has nothing to blur; you need a `ShaderEffectSource` of the backdrop. |
| 7 | 🟠 | Containerfile installs `pipewire pulseaudio jack-audio-connection-kit kdeconnect qt6-qtquickcontrols…` (env) | `pulseaudio` and `jack-audio-connection-kit` **conflict** with Fedora's `pipewire-pulseaudio` and `pipewire-jack-audio-connection-kit`. `kdeconnect` pulls in KDE and isn't needed. Quick Controls 2 is part of `qt6-qtdeclarative` in Qt 6 (the listed package names are Qt 5–era and need checking). No compositor, `flatpak`, `NetworkManager-wifi` or firmware packages are listed. |
| 8 | 🟠 | Kiosk compositor (Weston/labwc) is fine with the shell as a client (env, project) | It's fine for Phase 0. For the product, the shell must **overlay running games** (Guide menu, volume OSD, notifications) and **switch between apps**. A client can't do that under a kiosk shell. Either the shell is the compositor or the compositor has an overlay protocol. See ADR-002. |
| 9 | 🟠 | Comparison omits **cage**, **gamescope** and **KWin** (all) | gamescope is SteamOS's console-mode compositor (HDR, VRR, FSR, frame limiting) and the most relevant prior art. cage is the reference kiosk compositor. |
| 10 | 🟠 | No prior art cited (all) | Several projects already do much of this: **Bazzite / Universal Blue** (Fedora bootc images with a gamescope console session), **ChimeraOS** + **OpenGamepadUI** + **InputPlumber**, **SteamOS**, **Plasma Bigscreen**, **Kodi/LibreELEC**. These should be evaluated before building from scratch. |
| 11 | 🟠 | bootc "internally uses rpm-ostree clients" (project) | bootc uses ostree (and composefs) directly. rpm-ostree is optional on bootc hosts. |
| 12 | 🟠 | `/etc` is "overlayed" and user data lives "on a separate volume" (project) | `/etc` is persistent and mutable, with a 3-way merge on upgrade. `/var` (including `/var/home`) is on the same filesystem by default. Factory reset therefore has to be designed; it doesn't come for free. |
| 13 | 🟠 | PINs via systemd-homed "as in the Fedora bootc guide" (project) | I couldn't confirm that this guide exists. homed authenticates with a password or a FIDO2/PKCS#11 token PIN, not a 4-digit console PIN. A homed home dir is **locked while its user is logged out**, which blocks background downloads and save sync for other profiles. |
| 14 | 🟠 | Running the shell as one process and the apps "as the profile's user" (project) | No mechanism is specified. Wayland sockets are per user, so launching an app as another Unix user needs socket ACLs or a security-context-v1 listener. This core architecture gap is now ADR-004. |
| 15 | 🟠 | Flatpak gives a "mobile-like permission UI" for network, USB and similar (project) | Flatpak permissions are **static at install time**. Runtime prompts exist only for portal-mediated access (files, camera, location…). Network can't be prompted for at runtime. |
| 16 | 🟠 | Proton for "a Windows EXE … launched from bundle" plus a "GUI for selecting Proton versions" (project) | Proton outside Steam is unsupported (umu-launcher is the community route). Steam already has a per-game Proton selector. |
| 17 | 🟠 | Phase 0 boots QEMU "in Wayland-on-X11 mode" (project) | That isn't a QEMU mode. In the VM the compositor runs on DRM/KMS (virtio-gpu). Wayland-on-X11 or nested is only a host-side dev convenience. |
| 18 | 🟠 | Test HDMI-CEC (ui) | Most PC GPUs **don't expose CEC**. It needs a USB-CEC adapter (Pulse-Eight) and libcec. |
| 19 | 🟡 | exFAT "patent-license aside", NTFS "read-only if needed" (project) | exFAT has been in the mainline kernel since 5.7 and its patents were released to OIN. The `ntfs3` kernel driver and ntfs-3g are both read-write. |
| 20 | 🟡 | Qt AM is "GPL/LGPL" and "business use would need a Qt licence" (project) | Qt AM and QtWaylandCompositor are **GPLv3 or commercial**. GPLv3 doesn't forbid business use; it requires releasing the compositor's source. Qt Quick itself is LGPLv3. |
| 21 | 🟡 | QtWayland "zero-copy textures (`wl_subsurface`)" (ui) | Zero-copy comes from dmabuf/EGL buffer sharing. `wl_subsurface` is unrelated. |
| 22 | 🟡 | labwc link `github.com/zakarumych/labwc` (project) | The correct repo is `github.com/labwc/labwc`. |
| 23 | 🟡 | `QT_WAYLAND_HARDWARE_INTEGRATION=wayland-egl` needed for blur (project) | That's a compositor-side variable, and the client default is already EGL. It isn't needed. |
| 24 | 🟡 | `WorkerScript` for "gamepad polling, JSON parsing, network fetch" (ui) | Input polling doesn't belong in JS. I/O goes in the Rust services, and WorkerScript is for pure CPU work only. |
| 25 | 🟡 | `/mnt/media` with custom udev rules (project) | Use udisks2 (`/run/media/<user>`) and talk to it over D-Bus. |
| 26 | 🟡 | "Vulkan optional (QtQuick uses OpenGL)" (ui) | Qt 6 Quick renders through RHI and can use Vulkan. OpenGL is the default on Linux. |
| 27 | 🟡 | Boot to shell in ~5 s (ui) | That's not realistic from power-on with UEFI, GRUB and initramfs on a NUC. The KPI now measures from kernel start and adds suspend/resume as the main "instant-on" path. |
| 28 | 🟡 | Input latency < 50 ms "end-to-end" (ui) | A TV alone can add 10–100 ms. The KPI is now evdev event → frame presented, which can be measured on our side. |
| 29 | 🟡 | Roadmap of ~30 days per phase, about 7 months for a TV OS, console, store, SDK and media centre | Not realistic. Dates have been removed and phases are gated by exit criteria. |

## 4. Gaps (not covered by any document)

**Architecture**
- **Compositor ownership.** Whether the shell is the compositor or a client decides overlays, app switching and focus. (ADR-002)
- **Input arbitration** between the shell, games and Steam Input. (ADR-003)
- **Session and user model.** What starts the shell, as which Unix user, and how apps launch as profile users. (ADR-004)
- **IPC between shell and services.** D-Bus, and which interfaces. Privilege model via polkit. (00-overview §4)
- **Project licence.** This drives the GPLv3 Qt components decision.

**Platform**
- Automatic rollback (greenboot), image signing (cosign plus `containers-policy.json`), registry hosting and update channels.
- **Secure Boot** with out-of-tree modules (NVIDIA, xone/xpadneo) needs akmods plus MOK signing.
- Full-disk encryption with TPM2 auto-unlock. Without it, the PIN is not a security boundary.
- Factory reset semantics, given that `/etc` and `/var` persist.
- A controller-driven installer and **first-boot setup (OOBE)**: language, network, first profile, admin PIN. Anaconda needs a keyboard and mouse.
- Suspend/resume and wake-from-controller. Power-button behaviour.
- A Windows-host test strategy. QEMU on Windows has no KVM, only WHPX, and virgl support is limited there. GPU KPIs need real hardware early.
- Logging, crash reporting and telemetry policy.

**Media and display**
- **Codec licensing.** Fedora's Mesa ships with H.264/HEVC VA-API decode disabled. Enabling it means RPM Fusion `mesa-freeworld` or similar, which is a redistribution decision.
- **Streaming DRM.** Netflix, Disney+ and others need Widevine. Linux gets L3 only, in browsers, with capped resolution. This needs stating plainly in scope.
- HDR, VRR, 4K@120, **refresh-rate matching** for video (23.976 Hz), audio passthrough (AC3/DTS/Atmos over HDMI).
- Remote controls: Bluetooth remotes, IR, CEC adapters.

**Apps and ecosystem**
- **Reuse Flathub** as a catalogue (filtered by AppStream gamepad support) rather than starting from an empty store.
- **Parental controls and content ratings.** AppStream OARS plus `malcontent` already exist.
- Store backend: hosting, review process, payments (out of scope?), app signing keys.
- Web-app runtime, if any (QtWebEngine?), and what APIs it exposes.
- Notifications, global search, cloud saves and account sync.

**UX and quality**
- Accessibility beyond reduced motion: text scaling, high contrast, screen reader (Orca on Wayland is limited), subtitles.
- Internationalisation: string extraction, locales, and RTL readiness.
- An MVP definition. The documents read as "everything at once".

## 5. Decisions still needed from the owner

These are recorded as ADRs with a recommendation in [00-overview.md §5](specs/00-overview.md). The ones that change direction most:

1. **ADR-001 — build vs. derive.** Base on Universal Blue / Bazzite components (gamescope session, InputPlumber, NVIDIA images) or start from plain `fedora-bootc`?
2. **ADR-002 — compositor.** QtWaylandCompositor (shell = compositor, GPLv3) is recommended, with a Phase 1 spike against gamescope.
3. **Project licence** (GPLv3 makes ADR-002 free of licensing friction).
4. **Codec / RPM Fusion policy** for hardware video decode.
