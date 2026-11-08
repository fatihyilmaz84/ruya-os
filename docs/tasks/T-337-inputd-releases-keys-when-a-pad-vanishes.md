# T-337 - ruya-inputd: a pad that vanishes never leaves a key held, and two pads share keys safely

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-inputd), scripts · Size: S · Owner: builder

## Goal
`ruya-inputd` turns every gamepad into key events on one shared virtual keyboard ("RuyaOS Navigation"). If a pad disappears (batteries, link loss, idle disconnect) while a button, a d-pad direction or a stick direction is held, its pump thread ends on the read error and the key stays pressed on the virtual keyboard: the shell sees a stuck Down or Accept, and every other pad's input is wrong until some pad presses and releases that key. With two pads a second problem exists: both write to the same keys, so pad B letting go of Down releases it while pad A still holds it.

## Read first
- `services/ruya-inputd/src/linux.rs` (`pump`: the loop ends on `fetch_events` error; `emit` takes the shared `Mutex<VirtualDevice>`), `mapping.rs` (`Mapper`: `button` keeps no state, `hat` and `stick` keep one `Option<NavKey>` per axis; the pure tests in the file)
- `docs/tasks/T-264-controller-registry-and-slots-service.md` (the registry may replace this shared keyboard later: keep the fix small and in `mapping.rs`, which compiles on every host)
- `scripts/vm-inject-key.py`, `scripts/vm-devices-check.sh` (how checks talk to input devices)

## Scope
1. **Pure core (`mapping.rs`, host-testable):** `Mapper` records which `NavKey`s its pad holds (buttons too) and gets `release_all() -> Vec<KeyEvent>` (a release for every held key, then empty). A small shared `KeyBoard` (a count per `NavKey` across pads) turns pad-level events into keyboard events: press only on 0 -> 1, release only on 1 -> 0; `KeyBoard::pad_gone(mapper)` releases what that pad held (decrementing, so another pad's hold survives).
2. **Wire it (`linux.rs`):** `pump` passes events through the shared `KeyBoard` (the existing `Mutex` already serialises), and on **every** exit path of the loop (read error, node gone, thread unwinding) calls `pad_gone` and emits the releases. Log `ruya-inputd: <name> gone: <err>; released <keys>` (INFO, T-335 style).
3. **VM check:** an `inputd` step in `scripts/vm-devices-check.sh` (python3 standard library only: create a virtual gamepad through `/dev/uinput`, hold DPAD_DOWN and BTN_SOUTH, destroy the device, then read the key state of the "RuyaOS Navigation" device with the `EVIOCGKEY` ioctl and assert KEY_DOWN and KEY_ENTER are up; then two virtual pads: pad 1 and pad 2 hold Down, pad 2 releases, Down is still down; pad 1 releases, Down is up). If the image lacks `/dev/uinput` access for root, say so and mark the step UNVERIFIED rather than skipping silently.

## Out of scope
- Grabbing the physical devices (B-006 / InputPlumber), key repeat, remapping, per-slot virtual pads (T-264, T-266), pad activity for the idle clock.

## Acceptance criteria
- [ ] Tests in `mapping.rs`: `release_all_releases_held_buttons_hats_and_sticks`, `release_all_twice_releases_nothing_the_second_time`, `two_pads_holding_the_same_key_press_it_once`, `a_key_stays_down_until_the_last_pad_lets_go`, `a_vanished_pad_releases_only_what_it_held`, `a_pad_that_vanishes_holding_nothing_emits_nothing`. Revert check: `pad_gone` doing nothing turns the third-from-last red.
- [ ] `cargo test`, `cargo clippy` for the workspace via `.\scripts\dev.ps1 test` ALL GREEN (the Linux-only `linux.rs` part compiles in CI/WSL: run `dev.ps1 rust` and say if Linux code was not built on this host).
- [ ] VM (lead run): `vm-devices-check.sh inputd` as above. Outcome `Verified: host (vm pending: vm-devices-check.sh inputd)`.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (ruya-inputd paragraph: held keys are released when a pad goes), `docs/dev-setup.md`.

## Hints
- `mapping.rs` is compiled on Windows with `allow(dead_code)`; keep the new types there so the tests run on this host. `linux.rs` stays a thin loop.
- Land this before T-264 so the registry starts from a service that cannot stick a key.

## Outcome
_Filled in by the implementer._
