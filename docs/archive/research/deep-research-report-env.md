# Architecture and Development Workflow

We **strongly agree** with the review’s recommendations. We will **use Wayland** for the graphical session, but avoid reinventing a compositor from scratch. We will also adopt Podman (with Podman Machine on Windows) for building the Fedora bootc image, and use QEMU as our primary test environment. Below are the confirmed decisions and steps for Phase 0 development:

- **Fedora bootc base:** We will build a custom Fedora image using `bootc`-compatible containerfiles. Developers can work on Windows (using VS Code or similar) but the actual image build must happen in a Linux environment (e.g. a Podman Machine VM). The Podman Desktop “bootc” extension runs on Windows but requires a **rootful Podman Machine** with ≥6 GB RAM. In practice, we’ll use `podman build` on the Fedora base image (e.g. `quay.io/fedora/fedora-bootc:<version>`), adding only the packages we need (shell runtime, system services, drivers, etc.). This approach “reuses established primitives” and avoids unnecessary desktop components.
- **Verification with `bootc`:** After building our image, we will run `bootc container lint` inside the container to ensure it’s bootc-compatible (it checks for the `containers.bootc=1` label, correct kernel layout, etc.). Then, we test installation by running the image with `--privileged` and using `bootc install to-disk /dev/vda` (or similar) to write it to a virtual disk. This records the pull reference for future updates. The installed system can be examined with `sudo bootc status` and updated with `sudo bootc upgrade` and rolled back with `sudo bootc rollback`.
- **Wayland and compositor:** We will run Qt Quick/QML on Wayland. Rather than writing a custom compositor, we will initially use a minimal existing compositor. Options include running the QML shell as a Wayland client under *Weston* or *Labwc*, or using Qt’s WaylandCompositor module (which provides a QML-based compositor example).  For Phase 0, using Weston (with a simple kiosk-shell or layer-shell setup) is safest. The Qt shell will run full-screen, and we’ll configure the compositor to give it focus and handle inputs. In short, we will **start with an existing compositor** (e.g. Weston or KWin) to host our QML interface, with the possibility of migrating to a custom QtWayland compositor later once the UI design is stable.
- **QEMU Virtual Testing:** We will use QEMU for our virtual hardware tests. On Windows, this may run inside the Linux build VM or via Podman Machine. We should confirm that the built image boots in QEMU (UEFI firmware, virtio disk) and that the Qt shell appears. The review’s suggestion is to do a “VM Boot & Compositor Test” in QEMU. We will create a small VM with 4–8 GB RAM, boot the image, and verify:
  1. The kernel loads and a Wayland session starts.
  2. A basic Qt Quick application (our shell) appears, filling the screen.
  3. Input (keyboard/virtual controller) is accepted.
  4. No desktop environment is present.
- **Simulated Update/Rollback:** Inside the QEMU VM, we will test bootc’s update flow before adding any app code. For example, build a second container image (e.g. a small version bump), run `sudo bootc upgrade`, then reboot the VM and ensure the new image is applied or rolled back properly. This verifies system resilience and ensures our image-based updates work before adding features.

## Podman-Based Build Workflow

To support Windows-host development, we will document how to use Podman Desktop:

- **Podman Desktop / Podman Machine:** Install Podman Desktop ≥1.10 on Windows and create a Podman Machine in “rootful” mode with at least 6 GB RAM. This gives us a Linux VM with Podman and privileged access for building bootable images. Podman Desktop will run as a regular user on Windows, but the build process (`bootc-image-builder`) will request sudo inside the VM.
- **Containerfile Example:** Our Containerfile will begin like:  
  ``` 
  FROM quay.io/fedora/fedora-bootc:44
  RUN dnf -y install qt6-qtwayland qt6-qtquickcontrols2 qt6-qtquickcontrols \
      pipewire pulseaudio kdeconnect jack-audio-connection-kit bluez usbutils ntfs-3g \
      && dnf clean all
  ```  
  (This is illustrative – adjust packages as needed.) After building (`podman build -t myconsole:latest .`), we verify with: `podman run --rm myconsole:latest bootc container lint`.
- **Building and Installation:** Once the container is verified, we install it to a disk (e.g. in QEMU) by running:  
  ```
  sudo podman run --rm --privileged --pid=host --ipc=host \
      -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
      --security-opt label=type:unconfined_t \
      myconsole:latest \
      bootc install to-disk /dev/vda
  ```  
  This command is exactly as given in the bootc documentation. It writes the image to `/dev/vda`, which QEMU will use as the VM disk.

## Testing and Validation

- **VM Profiles:** We will set up one or more QEMU VM profiles (e.g. with virtio disk, UEFI, 2–4 CPU cores, 4+ GB RAM). A basic test VM should boot the installed image, show the shell, and allow basic navigation.  
- **Compositor Behavior:** Ensure the Wayland compositor (Weston or chosen compositor) launches our shell automatically (e.g. via an autostart or init script) and that no login screen appears. Controller or keyboard arrow keys must move focus in the UI.  
- **Audio and Input:** Test audio routing early. Verify PipeWire (and/or PulseAudio compatibility) sends sound to the default output (HDMI/sound card) and accepts Bluetooth or USB controllers. We should handle cases like plugging in a headset or switching outputs.  
- **Recovery Path:** Confirm that if the shell or an app crashes, we can return to the shell without reboot. Plan for a fail-safe (e.g. if `weston` dies, restart it). Ensure Ctrl+Alt+F (or similar) returns to a safe console. Also test that an interrupted OS update does not brick the VM.

## Packaging and App Ecosystem

We will **not build an entirely new sandbox from scratch**. Instead:

- **Application Bundles:** Investigate using **OCI containers or Flatpak-like bundles** for third-party apps. For example, `.cbundle` could simply wrap an OCI image or Flatpak reference. This leverages existing tooling for sandboxing and dependency management. Flatpak already provides per-app isolation, permissions, and distribution infrastructure. We can customize a “console app” manifest on top of OCI, but reuse container technology.  
- **Games and Dependencies:** For games, we support “portable bundles” (self-contained) and “repo-managed” installs. Shared runtimes (like Proton, emulators) should be deployed as separate Flatpak or container runtimes. We will ensure each game’s manifest is validated and signed, but the underlying installation can leverage existing package formats.  
- **Repositories:** Use a single runtime (like ostree or flatpak repo) under the hood with multiple logical sources (official, community, private). Repository metadata must be signed and versioned. The UI will mark apps by source (official vs community). Users can disable a repo, and rollback app updates if needed.

## Summary

We will proceed with **Fedora bootc + Podman + Wayland** for the system base. Our first priority is proof of concept: build and boot the image, start the Qt/QML shell under Wayland, and verify update/rollback functionality. Only after that is solid will we layer on multi-user profiles, media clients, game streaming and other features. This plan incorporates the review’s advice (reuse Podman with rootful mode, test in QEMU, be cautious about a custom compositor and packaging), ensuring a robust foundation for the console OS. All steps will be documented, including build commands, VM configs and any limitations discovered, so the LLMs can implement them reliably.  

**Sources:** We follow the Fedora/bootc guidelines and best practices, and industry examples (e.g. Weston kiosk shells, Flatpak) in shaping this architecture.