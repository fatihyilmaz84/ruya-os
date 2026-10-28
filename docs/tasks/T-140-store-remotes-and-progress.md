# T-140 — Store in the image: the spec's remotes, AppStream refresh and real install progress

Status: todo · Phase: 3 · Depends: T-134 · Area: image, services · Size: M

## Goal
The store in the VM lists real, named apps from the sources spec 03 §4.2 names (Flathub), not the 524 unnamed apps of Fedora's own OCI remote, and an install shows progress between 0 and 100.

## Read first
- `docs/specs/03-services-and-apps.md` §4.2 (sources table) and §4.3 (as built, T-134); ADR-005 and ADR-011 in `00-overview.md`
- `docs/tasks/T-134-store-service-core.md` Outcome ("Found in the VM")
- `services/ruya-store/src/flatpak_cli.rs` (`run`, `remote_apps`, `appstream`), `src/flatpak.rs` (`parse_progress`), `src/service.rs` (`refresh`)
- `image/build/20-base.sh` (installs `flatpak`), `scripts/vm-store-check.sh`

## Scope
1. **Remotes in the image:** Fedora's `fedora` OCI remote (`oci+https://registry.fedoraproject.org`, added by a Fedora package; find which with `rpm -qf` on the `remotes.d` file) is not in the image. `flathub` is, as a system remote with its signing key, added the way Fedora does it (a `.flatpakrepo` in a `remotes.d` directory that flatpak reads, or a one-shot unit), with no network access needed at build time beyond what `build.sh` already has. No `ruyaos` remote yet (it does not exist; out of scope).
2. **AppStream refresh:** the service runs `flatpak update --appstream --system` (per remote) in the background after start and after `AddRemote`, then re-reads the catalogue and sends `InstalledChanged`, so Flathub apps have names, summaries and icons. A failure (no network) leaves the cached data and logs once.
3. **Real progress:** `flatpak` prints percentages only on a terminal. Give the `run` child a pseudo-terminal (or another reliable source of progress), keep parsing in the pure core (`parse_progress`, unit-tested with captured terminal output including `\r` redraws and colour codes), and keep `JobProgress` non-decreasing. Pure-Rust crates only (`services/CLAUDE.md`).
4. `vm-store-check.sh`: the test app gets a payload large enough (e.g. 50 MB of random data) that an install from the local repo shows at least one intermediate `JobProgress`; add a check that `fedora` is absent and `flathub` is present and signed.

## Out of scope
- Flathub filtering by controller support and "Show all apps" (T-111, shell), the `ruyaos` remote, update scheduling, `GetApp` permission prompts.

## Acceptance criteria
- [ ] Unit tests: progress parsing from captured terminal output (redraws, escape codes, phases); progress never decreases; AppStream refresh failure keeps the old catalogue (fake).
- [ ] VM (image from this commit): `RUYA_BOOT_OK`; `flatpak remotes --system` shows `flathub` (signed) and no `fedora`; `vm-store-check.sh` passes, including at least one `JobProgress` strictly between 0 and 100 for the test install (log excerpt in the Outcome).
- [ ] VM, with the guest online (slirp gives it the host's internet): after the AppStream refresh, `Search` for a well-known Flathub app (e.g. `org.supertuxproject.SuperTux`) returns it with a non-empty name and summary (output in the Outcome). If the VM has no internet, say so and mark this criterion unverified.
- [ ] `systemd-analyze security ruya-store` still OK (number in the Outcome); `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
# WSL: scripts/build.sh, make-disk.sh qcow2; then
.\scripts\smoke-test.ps1 -Keep    # and scripts/vm-store-check.sh in the guest (dev-setup.md, "Store check")
```

## Docs to update
- Spec 03 §4.2 (which remotes the image ships) and §4.3 (AppStream refresh, progress source), `docs/dev-setup.md` (store check additions).

## Hints
- A pseudo-terminal in pure Rust: `rustix` has `openpt`/`grantpt`/`unlockpt`/`ptsname` (`pty` feature); if that grows too much, `script -qfec` from util-linux (already in the image) is an acceptable wrapper. Either way set `TERM=dumb`/`NO_COLOR` where flatpak honours them, and strip escape codes in the parser anyway.
- The unit's `RestrictAddressFamilies` already allows network; a pty needs `/dev/ptmx`, which `PrivateDevices=yes` hides: check what the hardening allows and record any change and the new score.
- Flathub's `.flatpakrepo` carries its GPG key; ADR-005 requires signed remotes, and `AddRemote`'s signed-only rule must not be bypassed by the image route.
