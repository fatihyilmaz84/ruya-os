# T-319 — Xbox 360 wireless receiver (the "Xbox 360 dongle"): make it work and say so honestly

Status: todo · Phase: 2 · Depends: — · Area: image, services, shell, docs · Size: S · Owner: builder · Developer surface: none

## Goal
A player plugs in an Xbox 360 Wireless Gaming Receiver for Windows (Microsoft's, or a third-party clone with the same USB ids), switches on up to four Xbox 360 wireless pads, and each pad is detected, classified, named, shown with its battery and usable in the shell and in apps, with the guidance text for the sync buttons. Owner request, 2026-11-08: "xbox 360 dongle driver, if not supported yet". Not the Xbox One/Series Wireless Adapter (that needs out-of-tree drivers and Microsoft firmware: T-261, owner-level).

## Facts to verify first (public knowledge, **unverified in this repo**: nothing in `docs/`, `image/` or `ruya-inputd` mentions the 360 receiver)
- The in-kernel `xpad` driver supports the receiver (Microsoft ids `045e:0719` and `045e:0291`, driver type "Xbox 360 wireless"): no out-of-tree driver and **no firmware** is needed, unlike the Xbox One adapter. Each connected pad appears as its own input device while the receiver is the USB device; pads connect and disconnect without the USB device changing. Rumble and the battery level (power supply class) are provided by the driver.
- Pairing is done with the sync button on the receiver and on the pad, not with the OS: the shell can only explain it.
- If `xpad` is built as a module in the image kernel, the module must be present and auto-loaded by the USB alias (check `modinfo xpad`, `modules.alias` for the ids); a rootfs without it is the only thing that would need an image change.

## Read first
- T-261 (family table, classification table, hardware checklist: this task adds a row and a case, it does not duplicate the audit), T-199 (family detection and the "Controller connected" toast), T-260 (guidance text), T-203 (pairing flows), T-223 (battery), `services/ruya-devices` (`ListDevices`, `ListBatteries`, kinds), `ruya-inputd` (`linux.rs`), `docs/specs/03-services-and-apps.md` line about in-kernel drivers, `image/build/20-base.sh`, `docs/image-packages.md`

## Scope
1. **Image:** confirm `xpad` is available and autoloads for the two ids (fixture check on the module aliases in `scripts/check-image-manifest.sh` or a VM check); change the image only if it does not.
2. **Classification:** the receiver itself is a USB dongle, not a controller: it must not show as a pad or produce a "controller connected" toast; each pad behind it is `family xbox`, `kind controller`, name "Xbox 360 Controller" (or the driver's), battery from the power supply; unit tests on fixtures (udev property sets for the receiver and a pad node, built by hand, no hardware needed). Third-party clones with the same ids behave the same; unknown ids are not guessed.
3. **Lifecycle:** a pad connecting/disconnecting behind a plugged receiver raises the same toasts as any pad (T-199) and updates the battery list and the controller registry (T-264 when built); unplugging the receiver removes all its pads at once without a storm of toasts (one per pad is fine, one toast for the receiver is not).
4. **Guidance (T-260 text):** "Press the sync button on the receiver, then on the controller" in English and Turkish where the controller help lives; documented in `docs/developers/controller-input.md` (nothing else needed by apps, they see ordinary Xbox 360 pads, SDL already maps them).
5. **Docs:** add the row to the T-261 family table and to `docs/hw-checklists/controllers.md` (if they exist by then; otherwise leave the lines for T-261), `01-platform.md` (the 360 receiver is in-kernel, the One/Series adapter is not) and the STATUS Dell look-at list.

## Out of scope
- The Xbox One/Series Wireless Adapter, `xone`/`xow`/`xpadneo`, Microsoft firmware (T-261; researched in T-354); pairing UI (the dongle pairs by its own buttons); wake from suspend by the pad (T-262).

## Acceptance criteria
- [ ] Rust tests: classification of the receiver (not a pad), of a 360 pad behind it (family, kind, battery), of an unknown dongle with a similar name (not matched).
- [ ] Image: `modinfo`/alias check shows `xpad` loads for `045e:0719` and `045e:0291` (a manifest or VM check; `scripts/check-image-manifest.sh` green); no out-of-tree driver or firmware added.
- [ ] Shell test (mock): connect/disconnect toasts for a 360 pad, battery shown, receiver unplug leaves no stale pads; Turkish strings; screenshot of the guidance text if it is a visible change.
- [ ] `hw` (the owner or the Dell, a receiver and a 360 pad): listed in the Dell look-at list; Outcome says `Verified: host (hw pending: receiver)` until then.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: …, hw pending: …)`._
