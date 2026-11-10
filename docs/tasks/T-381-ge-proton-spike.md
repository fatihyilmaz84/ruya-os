# T-381 - Spike: GE-Proton outside Steam on RuyaOS (umu, runtime, display, size, licences, codecs)

Status: todo · Phase: 5 · Depends: — · Area: image, services (ruya-session launch), docs · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** The spike's output also names, as tasks: the run path for a Windows game outside `.play` (the prefix per game and profile, how such a game becomes a Library entry), which T-385 and T-402 assume and nobody owns; who hosts the `ruyaos` Flatpak remote and holds its signing key; the source mirror the owner asked for on 2026-11-10.

## Goal
Facts for ADR-025: a Windows test program and one real free Windows game run through GE-Proton on the Dell, from the shell, on a profile's Wayland socket, with sound and a pad; and the numbers and lists the owner needs (size, licences, codecs).

## Read first
- `docs/specs/00-overview.md` ADR-025, ADR-014, ADR-023 (per-profile sockets), ADR-024 (pads reach apps as virtual devices)
- `docs/specs/05-play-packages.md` §6 (runners, `runner.json`, Q2 display), §14 (licensing)
- `docs/specs/03-services-and-apps.md` (launch path in `ruya-session`), T-164 and T-358 Outcomes (Wayland sockets, GPU buffers), T-365 (profile sound)
- Upstream: GE-Proton releases (GloriousEggroll/proton-ge-custom), umu-launcher (Open-Wine-Components/umu-launcher), Flathub `org.openwinecomponents.umu.umu-launcher` if present, Flathub `com.valvesoftware.Steam.CompatibilityTool.Proton-GE`

## Scope (questions to answer, each with what was run)
1. **Run path:** GE-Proton through umu-launcher inside a Flatpak sandbox on the Dell (`flatpak run` of a test app that has GE-Proton mounted as an extension), launched by `ruya-session` as a profile user. Does the Steam Linux Runtime (pressure-vessel) work nested in Flatpak here, or does umu need `--no-runtime`?
2. **Display:** `PROTON_ENABLE_WAYLAND=1` (Wine's Wayland driver) on the per-profile socket: window, fullscreen, the GPU (not llvmpipe: check `drm-engine-render` in fdinfo), DXVK and vkd3d-proton. If it fails, measure what Xwayland in the compositor would need (a sketch, no build).
3. **Sound and pads:** pulse via `PULSE_SERVER` (T-365); a pad through SDL/XInput (today games see no pad until T-367: record that, test with the keyboard).
4. **Packaging:** the extension's name, branch per major, where the umu entry lives, how a pinned release tarball becomes the extension (checksum), size on disk and added image size (for T-195), and the same recipe for the other runner families of ADR-025 (Wine stable/staging, Wine-GE, UMU-Proton): which are open builds we may repackage, their upstream state (Wine-GE stopped in 2024?), sizes, and one shared `runner.json` schema for all.
5. **Licences and codecs:** the component list of the pinned release with each licence, the source-offer obligation, and which media codecs it carries (H.264, AAC, ...): the facts for the owner's questions in ADR-025.
6. **Steam:** how Steam's Flatpak picks a default compatibility tool (`config.vdf` `CompatToolMapping` "0"), and whether Flathub's Proton-GE compat-tool extension can be the same files as ours.

## Out of scope
- Building the image extension (T-382), the Steam default (T-383), developer docs (T-384), Xwayland itself.

## Acceptance criteria
- [ ] A spike report in this Outcome: one section per question above, with commands and numbers (FPS or frame times, CPU and GPU share, size).
- [ ] ADR-025 updated: the extension name, the display route, whether Wine stays; the owner questions rewritten with the facts.
- [ ] T-382..T-384 rewritten where the facts change their scope; a new task for Xwayland if the Wayland driver is not enough.
- [ ] `dev.ps1 docs` (or `test`) ALL GREEN.

## Hints
- The Dell is a test machine: anything goes over SSH (CLAUDE.md). Stop hand-started games by their `app-flatpak-*.scope` (lead-7 lesson).
- A small free Windows game with a GPU path (a DirectX 11 demo) beats a synthetic test.

## Outcome
_Filled in by the implementer._
