# T-465 — zram swap in the image, so frozen games can give memory back

Status: done · Phase: 2 · Depends: — · Area: image · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: vm (image 0.0.65-t465: `build.sh` passed `bootc container lint --fatal-warnings`, `make-disk.sh qcow2`, `smoke-test.ps1` printed `RUYA_BOOT_OK 0.0.65-t465`, `vm-swap-check.sh` ALL CHECKS PASSED)

**What was built.**
- `image/rootfs/usr/lib/systemd/zram-generator.conf`: `[zram0]`, `zram-size = min(ram / 2, 4096)`, `compression-algorithm = zstd`. This is the same path the `zram-generator-defaults` package uses, but that package is deliberately not installed (see below). The generator, `systemd-zram-setup@.service` and the SELinux label (`systemd_zram_generator_conf_t` for this path) were already in the image, so nothing else was needed: no new package, no new unit, `enabled-units.txt` unchanged.
- `scripts/vm-swap-check.sh` (exec bit set, added to the default list of `vm-queue.ps1`): device exists, `disksize` = min(RAM / 2, 4096 MiB) (+-1 MiB), algorithm `[zstd]`, `/dev/zram0` is the only swap with priority 100 and its setup unit is active, `vm.swappiness` = 60, `systemd-oomd` not failed and no unit sets `ManagedOOM*`, and a functional part: a transient service holds 256 MiB of compressible data, `memory.reclaim` pushes it out, cgroup swap use and zram `mm_stat` are read (compressed under half of original), and the swap is given back when the service stops. The service is stopped by an exit trap.
- Specs/docs: `01-platform.md` new section 1.4 (what swap, why, why not the defaults package, oomd, swappiness, the check), `image-packages.md` row, `dev-setup.md` paragraph.

**Decisions.**
- The task text says Fedora's default is `min(ram / 2, 4096)` and zstd. On Fedora 44 the `zram-generator-defaults` file is `min(ram, 8192)` with the kernel's default algorithm (lzo-rle), so the package would not be "the same thing". The image carries its own file with the numbers that were measured on the Dell (4 GB zstd on 8 GB).
- `systemd-oomd` is enabled in the image but `systemd-oomd-defaults` is not installed and nothing sets `ManagedOOMSwap=`/`ManagedOOMMemoryPressure=`, so oomd watches no cgroup and zram filling up cannot make it kill anything (checked in the built image: no `ManagedOOM*` under `/usr/lib/systemd` or `/etc/systemd`). No change to oomd made.
- `vm.swappiness` stays 60 (kernel default; no sysctl file). The measurements were taken at 60; raising it for zram would also push the running game out and needs its own measurement.

**VM results (4 GB VM).** disksize 1946 MiB = min(3892 / 2, 4096); `[zstd]` selected; `/dev/zram0 partition 1992700 KiB prio 100` the only swap; oomd active; reclaim moved 123 MiB of the holder into swap (200M was asked, the kernel gave less), zram stored 129,798,144 bytes as 1,474,912 (the repeating pattern compresses far better than a game; this proves the plumbing, not the 3.1x ratio); zram held 4096 bytes after the holder stopped.

**Negative run (in place of a revert test, there is no unit test here).** After `swapoff /dev/zram0` in the booted VM the check printed `FAIL: swap devices: none`, `FAIL: systemd-zram-setup@zram0.service: inactive`, `FAIL: swap priority:` and `SOME CHECKS FAILED`. (The config file itself was not reverted and rebuilt: that is a 30-minute image build; the check reads the running device, and an image without the file has no `/dev/zram0` at all, which is the first line of the check.) Host side: `lint-vm-checks.ps1` passes the new script (`bash -n`, exec bit).

**Notes.** The first `make-disk` failed with "Cannot allocate memory" (`dev.ps1 test` of the lead ran beside it); `SKIP_BUILD=1 scripts/image-chain.sh` reused the built image and passed. No other `vm-*.sh`/`dell-*.sh` check greps anything this diff changes (swap was absent before; `vm-security-check` baseline has no swap, port or setuid entry affected; the System page already reads swap and zram, so no shell change). Not tested: swap behaviour with a real frozen game and an i915 GPU (that is T-466 and the Dell).

**Lead queue note.** `vm-devices-check.sh system` compares `memory.swap_total_bytes` with `SwapTotal`; until now the VM had no swap, so its swap branch (`matches SwapTotal`) runs for the first time in the next queue.

**Files.** `image/rootfs/usr/lib/systemd/zram-generator.conf`, `scripts/vm-swap-check.sh`, `scripts/vm-queue.ps1`, `docs/specs/01-platform.md`, `docs/image-packages.md`, `docs/dev-setup.md`, this task file.
