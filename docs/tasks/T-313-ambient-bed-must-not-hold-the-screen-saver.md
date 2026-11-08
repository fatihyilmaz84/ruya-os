# T-313 — The shell's own ambient sound must not count as "something is playing"

Status: in-progress · Phase: 2 · Depends: — · Area: services (ruya-devices pipewire), shell (ambient loop, power saving), scripts (vm-power-saving-check) · Size: S · Owner: builder

## Goal
With the ambient sound theme on, the screen saver, display-off and sleep stages still start on Home. Today the shell's own ambient loop is a `Stream/Output/Audio` node in state `running`, so `Devices1.Audio.Playing` is true while the console sits at Home and the idle clock never advances (T-293 review, an old bug that the old `Audio/Sink` filter had as well).

## Read first
- T-293 Outcome and review (Inbox line "ambient bed"); `services/ruya-devices/src/pipewire.rs` (`parse_playing`, ~line 63), `docs/specs/03-services-and-apps.md` (Devices1 `Playing`), `api/dbus/org.ruyaos.Devices1.xml`
- the shell's ambient loop (`shell/src/sound/`, `main.cpp`, `AmbientLoop` in QML) and how it names its stream (`application.name`, `application.process.binary`, `media.role`)
- `shell/qml/IdleClock.qml` (how `Playing` holds the stages), `scripts/vm-power-saving-check.sh` (`audio` part)

## Scope
1. **Decide and implement** one rule, recorded in spec 03: the shell's own streams do not count. Preferred: the shell gives its streams a property (`media.role` = `Notification`/`Ambient` or a fixed `application.name`) and `parse_playing` skips nodes with that marker; an app's stream still counts. If the shell cannot set the property from Qt Multimedia, skip nodes whose `application.process.binary` is the shell's binary.
2. **Tests (Rust):** `parse_playing` hand-made dumps: an ambient shell stream running alone is false; the same plus a game stream running is true; a shell stream marked by the fallback property is skipped; the game stream corked next to the ambient one is false.
3. **Shell test:** with the ambient theme mocked on and `Audio.playing` false (the service answer after the fix), the idle clock reaches the saver stage.
4. **VM check:** `vm-power-saving-check.sh audio` first assertion passes with the ambient bed on (the script turns the ambient theme on first); Outcome `Verified: host (vm pending: vm-power-saving-check.sh audio)`.

## Out of scope
- A level or peak check for a player that streams silence; muting apps; T-164.

## Acceptance criteria
- [ ] The Rust tests above pass and fail when the skip rule is removed (revert check).
- [ ] Shell test: ambient on, no app: the saver stage is reached on the idle clock.
- [ ] Spec 03 states the rule; `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/specs/03-services-and-apps.md` (Devices1 `Playing`), `api/dbus/org.ruyaos.Devices1.xml` comment.

## Hints
- No contract signature change should be needed. Linux-only pieces (Qt Multimedia stream properties) are unverified on this host: say so and keep the fallback rule.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
