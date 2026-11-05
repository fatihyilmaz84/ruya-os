# T-180 — NetworkManager polkit: refuse every action `ruya-shell` doesn't need

Status: in-progress · Phase: 2 · Depends: -- (T-178 is merged; one image build at a time) · Area: image, services · Size: S · Owner: builder

## Goal
`50-ruyaos-network.rules` allows four NetworkManager actions for `ruya-shell` but returns `NOT_HANDLED` for the rest, so NetworkManager's own defaults (an active session may do many things without a password) stay open to the shell's user. Close it the way T-174 round 2 closed udisks2.

## Read first
- `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-storage.rules` (the pattern: allow list, then `NO` for the rest of the namespace) and `50-ruyaos-network.rules`
- `scripts/vm-storage-check.sh` lines ~45-65 (`pkcheck` against the service's pid: allowed and not-allowed lists)
- `services/ruya-devices/src/network.rs` (which NetworkManager calls the service really makes)
- `services/CLAUDE.md`, `image/CLAUDE.md`

## Scope
1. In the network rule, return `polkit.Result.NO` for every `org.freedesktop.NetworkManager.*` action of `ruya-shell` that is not in the allow list. Re-derive the allow list from what `network.rs` calls (Wi-Fi scan, connect, forget, saved networks); add an action only if the VM check shows the service needs it, and say why in the rule's comment.
2. Extend `scripts/vm-devices-check.sh` (network part) like `vm-storage-check.sh` does: `pkcheck` as the service's pid says YES for each allowed action and not-YES for a list of refused ones (at least `enable-disable-network`, `enable-disable-wifi`, `reload`, `settings.modify.hostname`, `checkpoint-rollback`, `wifi.share.open`). The existing network checks (scan, connect, forget) must still pass: that proves the deny list did not cut something the service needs.
3. Update the rule's header comment (it says other actions "stay" as they are).

## Out of scope
- The power and storage rules; changing what the shell can do in Settings > Network.

## Acceptance criteria
- [ ] VM (this task): build an image, `RUYA_BOOT_OK`, `vm-devices-check.sh check` ALL PASSED including the new pkcheck lines and the existing network scan/connect/forget; record the version tag.
- [ ] The rule file has no path that returns `NOT_HANDLED` for a NetworkManager action of `ruya-shell` (read in review); other users keep the default.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
Image recipe in `docs/dev-setup.md` (`build.sh`, `make-disk.sh qcow2`, `smoke-test.ps1`, then the check over SSH); end with `scripts\free-space.ps1`.

## Docs to update
- `docs/specs/01-platform.md` if it lists the polkit rules; `docs/dev-setup.md` if the check's use changed.

## Hints
- Copy `image/bib/config.toml` from the main checkout into your worktree before `make-disk.sh`.
- `pkcheck --action-id X --process <pid>` exit 0 = allowed, 1 = refused, 2 = would ask for a password.

## Outcome
Verified: vm (image 0.0.6-t180: `RUYA_BOOT_OK 0.0.6-t180`; `vm-devices-check.sh check` ALL CHECKS PASSED, 58 PASS lines, 0 FAIL; `dev.ps1 test` ALL GREEN).

Built:
- `50-ruyaos-network.rules`: the four allowed actions (`wifi.scan`, `network-control`, `settings.modify.system`, `settings.modify.own`) are unchanged, they are what `network.rs` calls (RequestScan, ActivateConnection, AddAndActivateConnection, Settings.Connection.Delete); the check proved none more is needed. Every other `org.freedesktop.NetworkManager.*` action of `ruya-shell` now returns `polkit.Result.NO`; only non-NetworkManager actions and other users return `NOT_HANDLED`. Header comment rewritten (it said the rest "stays" default).
- `scripts/vm-devices-check.sh` (network part): `pkcheck --process <ruya-devices pid>`: exit 0 for the four allowed, exit 1 for twelve refused (`enable-disable-network`, `-wifi`, `-wwan`, `-connectivity-check`, `-statistics`, `sleep-wake`, `reload`, `settings.modify.hostname`, `settings.modify.global-dns`, `checkpoint-rollback`, `wifi.share.open`, `wifi.share.protected`). The existing scan/connect/forget lines still pass.
- Spec `01-platform.md` (power/network paragraph) and `dev-setup.md` (devices check) updated.

Revert test: I put the HEAD version of the rule (no `NO` branch) over the installed file with a bind mount (SELinux label copied) and restarted polkit: the check failed 11 of the 12 refused actions (`sleep-wake` is already `no` in NetworkManager's policy, so it passes either way): `enable-disable-network/-wifi/-wwan/-connectivity-check/-statistics` and both `wifi.share.*` gave exit 0, `reload`, `settings.modify.hostname`, `settings.modify.global-dns`, `checkpoint-rollback` gave exit 2. After unmounting, it passed again (also three times after a polkit restart each).

Limits: the VM has no Wi-Fi adapter, so `Scan` only reaches NetworkManager's "no device" path and `Connect`/`Forget` only the unknown-network path in the service; none of them triggers a polkit check. What proves the allow list is therefore `pkcheck` as the service's own process (same pid, same subject polkit sees), not a real connect or forget on hardware. A real Wi-Fi connect/forget with the new rule is unverified (hw). Note for future checks: a rule file with the same name in `/etc/polkit-1/rules.d` does not shadow the one in `/usr/share`; both load.

Build note: the first `make-disk.sh` failed with "Cannot allocate memory" while `dev.ps1 test` ran at the same time; re-run alone it was fine.

Files: `image/rootfs/usr/share/polkit-1/rules.d/50-ruyaos-network.rules`, `scripts/vm-devices-check.sh`, `docs/specs/01-platform.md`, `docs/dev-setup.md`, this file. Deviations: none.
