# T-465 — zram swap in the image, so frozen games can give memory back

Status: todo · Phase: 2 · Depends: — · Area: image · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
The image has no swap at all: `zram-generator` is installed but has no config (`zram-generator-defaults` is missing). A frozen game keeps all its memory (a frozen SuperTuxKart race: about 1.0 GB, of which 680 MB i915 GPU buffers), and a third or fourth game can only end in the OOM killer. Compressed swap in RAM lets the kernel push a frozen game's memory out.

## Found (lead-11 study on the Dell, 0.0.64, 8 GB, 2026-11-11)
- A temporary 4 GB zstd zram: `memory.reclaim` on the frozen STK moved 261 MB of anon into 77 MB (3.1x); under a 5.2 GB memory hog the i915 shrinker released 343 of 697 MB of GPU buffers into swap; no OOM. Thaw took 198 ms; 42 MB faulted back within 0.4 s.

## Scope
1. A zram config in the image (Fedora's default is `zram-size = min(ram / 2, 4096)`, `compression-algorithm = zstd`), e.g. `/usr/lib/systemd/zram-generator.conf` under `image/`, or the `zram-generator-defaults` package if it is the same thing; say which and why.
2. Check how `systemd-oomd` (if enabled) treats swap with this config, and that `vm.swappiness` and friends stay at sane defaults; document the choice in `01` (platform).
3. A VM check (`vm-*-check.sh`): the zram device exists with the expected size and algorithm, and swap is on.

## Acceptance criteria
- [ ] VM (this task): `scripts/build.sh`, `make-disk.sh`, `scripts\smoke-test.ps1` RUYA_BOOT_OK, and the new check PASS; then `scripts\free-space.ps1`
- [ ] `01` says what swap the image has and why
- [ ] `dev.ps1 test` ALL GREEN

## Hints
- Planned by lead-11 from the frozen-game study. One image build at a time (LEAD.md 4b). The memory reclaim of frozen apps itself is T-466.

## Outcome
_Filled in by the implementer._
