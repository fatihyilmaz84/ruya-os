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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
