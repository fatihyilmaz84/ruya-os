# Licensing

RuyaOS is free and open source software.

| Part | Licence | Why |
|---|---|---|
| `shell/` (compositor + UI) | GPL-3.0-or-later | Links Qt Wayland Compositor (GPLv3) per ADR-002 option A |
| `services/` (Rust) | MIT OR Apache-2.0 | Rust ecosystem convention; usable as libraries elsewhere |
| `image/`, `scripts/`, `tests/` | GPL-3.0-or-later | Same as the shell |
| `docs/` | CC-BY-4.0 | Documentation |

Full texts are in [`LICENSES/`](LICENSES/). The CC-BY-4.0 text is available at https://creativecommons.org/licenses/by/4.0/legalcode.

The built OS image also contains third-party software under its own licences, including non-free redistributable components from RPM Fusion: the NVIDIA driver and patent-encumbered codecs (ADR-009). Each image ships an SBOM listing them.
