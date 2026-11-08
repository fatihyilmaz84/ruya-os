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
Verified: host (vm pending: vm-devices-check.sh inputd)

Checks: `dev.ps1 test` ALL GREEN (940 QML passed, 73 skipped; Rust incl. 13 ruya-inputd tests).

Built:
- `mapping.rs`: `Mapper` counts the sources behind each key (button, hat, stick; a key two sources hold is one pad-level press and one release) and gets `release_all()`; new `KeyBoard` (`route`, `pad_gone`) counts pads per key: press on 0 -> 1, release on 1 -> 0. A repeated press of one button is ignored; a release with no press seen still passes through `Mapper::button` (the existing test needs it) and `KeyBoard` ignores a release with nothing counted.
- `linux.rs`: `Output { device, board }` behind the one `Mutex`; a `Pad` guard whose `Drop` runs `pad_gone`, writes the releases and logs `ruya-inputd: <name> gone: <err>; released <keys|nothing>`. Drop runs on read error, return and unwinding (the lock tolerates poison so one panicked pump cannot block the others' releases).
- `scripts/vm-devices-check.sh inputd` (not part of `check`): virtual pads through `/dev/uinput` (python3 stdlib), `EVIOCGKEY` on "RuyaOS Navigation"; vanished pad with Down + A held; two pads sharing Down; the journal line; no `/dev/uinput` access prints `UNVERIFIED`.
- Docs: `00-overview.md` ADR-003 paragraph (where `ruya-inputd` is described; `03` has no such paragraph), `dev-setup.md`.

Proofs: the six named tests plus `a_key_held_by_two_sources_of_one_pad_is_released_once` in `mapping.rs`. Revert check: `KeyBoard::pad_gone` made to return nothing (hand mutation, `cargo test -p ruya-inputd`, file restored and re-run green): 2 tests red, `a_key_stays_down_until_the_last_pad_lets_go` and `a_vanished_pad_releases_only_what_it_held`. `linux.rs` type-checks via `dev.ps1 rust`'s Linux-target clippy (`x86_64-unknown-linux-gnu`); it was not run or linked on this host. The check script's `bash -n` and the python body's `py_compile` pass; the check itself ran nowhere (needs the VM).

Files: services/ruya-inputd/src/mapping.rs, linux.rs; scripts/vm-devices-check.sh; docs/specs/00-overview.md, docs/dev-setup.md.

Round 2 (review):
- `Mapper::button` now returns nothing for a release it never saw pressed (it passed `(key, false)` through, so `KeyBoard` subtracted from another pad's hold, or the d-pad's unseen release lifted a key the same pad's stick held). `buttons_map_to_navigation` now presses East before releasing it: it encoded the old stateless mapper, which reported every release. New test `a_release_never_seen_pressed_does_not_release_another_pads_key` covers both cases; revert check: putting back `return vec![(key, false)]` turns exactly that test red (13 passed, 1 failed), restored and green (14).
- The `gone:` log now lists the keys the pad held (`Mapper::held_keys`), not the keys the shared keyboard released (a key another pad holds stays down); the 00-overview sentence says so.
- `linux.rs`: a `Serving` guard removes a pump's path from `active` however the thread ends (a panic included).
- `vm-devices-check.sh` header: `inputd` sends real Down and Enter to the running shell; run it last or on a throwaway focus.
