# T-218 — HDR on Linux: feasibility spike and plan

Status: todo · Phase: 4 · Depends: — · Area: image, shell · Size: M · Owner: lead

## Goal
Find out, with measurements on real hardware, whether and how the console can output HDR, and write down a plan the owner can decide on. Owner request, 2026-11-06: "HDR support if possible on Linux". Spec 02-2.4 lists HDR/VRR as stretch goals that "depend on ADR-002 (gamescope supports both; QtWaylandCompositor support is unverified and needs a spike)". This is that spike; the output is an ADR (Proposed) and follow-up tasks, not product code.

## What is known (verify, do not trust)
- The shell is the compositor on Qt `eglfs_kms` (ADR-002 option A); Qt's eglfs KMS integration sets SDR modes and has no HDR scan-out path (no `HDR_OUTPUT_METADATA`, no `Colorspace`).
- Linux KMS exposes HDR per connector: `HDR_OUTPUT_METADATA` and `Colorspace` properties (kernel 6.x, driver dependent), `max bpc`; the sink's HDR static metadata is in the EDID (CTA-861 HDR block). Mesa has Vulkan HDR (WSI) on AMD and (recent) Intel; NVIDIA's proprietary driver has its own state. Wayland has the colour-management protocol (`wp_color_management_v1`) for apps and the compositor.
- gamescope (Valve) implements HDR and VRR for a nested/embedded session on AMD and Intel and is the proven route on Linux; KWin 6 and Mutter have desktop HDR.
- The Dell: Intel UHD 630 (Gen9.5; HDMI 2.0 needs an LSPCON on many boards, DisplayPort is simpler), the owner's monitor (Samsung Odyssey G7 32", HDR600) and TV capabilities decide what can be tested.

## Scope (all findings recorded, with commands and outputs, in the Outcome)
1. **Hardware facts on the Dell:** for each connected connector: the EDID HDR block (`edid-decode`), the KMS properties (`modetest -c` / `drm_info`): `HDR_OUTPUT_METADATA`, `Colorspace`, `max bpc`, `vrr_capable`; kernel and Mesa versions in the image; what the Intel driver supports on this platform; the same for a QEMU virtual GPU (probably nothing).
2. **Route A, HDR through gamescope for games:** run gamescope on the Dell with `--hdr-enabled` (a test app, a Vulkan HDR test such as `vkcube`/`hdr-test` clients, or a Proton game if available) under the existing shell session or on another VT; report: does the monitor switch to HDR mode, picture correct (PQ, peak), tone-mapping of SDR content, what is needed in the image (package, `CAP_SYS_NICE`, seat access), and how the shell would hand the screen over and back.
3. **Route B, HDR in the shell itself:** what it would take: KMS HDR properties set by us (a small C++/Rust helper via `libdrm` called from the shell), Qt RHI HDR swap chain formats on eglfs (is `QRhiSwapChain::HDR10` reachable?), SDR UI composited into an HDR output (the reference white, `sdr white level`), cost; a minimal experiment: set `HDR_OUTPUT_METADATA` on the shell's output while it runs and see what the sink does. A realistic yes/no and effort estimate.
4. **Route C, the Wayland colour-management protocol** for app surfaces in our `QtWaylandCompositor` shell (not available in Qt 6.11? check): effort/risks.
5. **Recommendation:** an ADR (*Proposed*) in `00-overview.md` comparing the routes: effort, what works on which GPUs (Intel, AMD, NVIDIA), what the player gets (HDR in games only, HDR everywhere), risks, and a proposed phasing with follow-up tasks (to be written by the lead after the owner decides); a short list of what to buy/test (a Gen11+ Intel or AMD box, an HDR TV).

## Out of scope
- Implementing HDR in the product, Dolby Vision, HDR10+ dynamic metadata, HDR tone-mapping tuning, calibration UI, HDR for video apps (separate, with refresh-rate matching: T-222).

## Acceptance criteria
- [ ] The Outcome contains the measurements for Scope 1 (a table per connector) and for each route the experiment's result and a clear yes/no/partially with the evidence.
- [ ] The ADR (*Proposed*) exists in `docs/specs/00-overview.md` with the recommendation, phasing and owner decision it needs; `STATUS.md` lists it under Open owner decisions with options and a recommendation.
- [ ] No regression: `dev.ps1 test` ALL GREEN if any file was touched; experiments leave the Dell as found (documented how to undo them).
- [ ] If the experiment needs packages, they are installed in a temporary overlay (`bootc usroverlay`) or a container on the Dell, not committed; a follow-up lists what the image would need.

## Docs to update
- `00-overview.md` (the ADR), `02-shell.md` §2.4 / `03` Display (what is true now), `STATUS.md` (owner decision).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: findings per route, the recommendation, follow-ups._
