# T-214 — Developer guide: the complete set, with a sample game that follows it

Status: in-progress · Phase: 2 · Depends: — · Area: docs, scripts · Size: M · Owner: builder

## Goal
A developer who has never seen RuyaOS can build a game or app, run it on a RuyaOS dev machine, make it behave well (controller, full screen, saves, stop), and publish it, using only `docs/developers/`. **Priority task** (owner, 2026-11-06: "make the developer documentation also a priority"): outside developers are the way the console gets games. `docs/developers/README.md` is the index and `saves-and-data.md` is written (by the lead, the model for tone and depth: short rules, examples that run, a checklist, a clear line between "built" and "planned").

## Read first
- `docs/developers/README.md`, `docs/developers/saves-and-data.md` (style and the status convention), `docs/specs/03-services-and-apps.md` §4 (format, sources, store, permissions, **§4.5a app data**, §4.6 SDK), §5; `docs/specs/02-shell.md` §1.5 (full-screen apps), §4.3 (focus/controller rules), Guide overlay; `docs/specs/00-overview.md` (scope, ADR-004 per-profile users, ADR-010 audio)
- `api/dbus/org.ruyaos.Session1.xml` (how apps start/stop: 5 s grace), `docs/dev-setup.md` (dev image, SSH key, VM), `scripts/vm-session-check.sh` (how a local Flatpak test app is built and installed in the guest: the sample's packaging follows it)
- The code decides what is true: read it before writing a claim. Anything not built yet is written as **planned** with its task id.

## Scope
Write these chapters in `docs/developers/` (Markdown, one file each, linked from the README table, whose Status column you update):
1. **Getting started:** prerequisites (Linux or WSL with `flatpak` and `flatpak-builder`), the Flatpak runtime to use (state which: check `docs/specs/03` and what the dev image has), a minimal manifest, building and exporting to a local repo, getting it onto a RuyaOS dev machine (dev image in QEMU per `docs/dev-setup.md`, or hardware over SSH), running it from the shell's Games row; what a developer sees when it works.
2. **AppStream metadata:** required fields (id rules, name, summary, description, developer, licences, screenshots), `Categories=Game;`, **content rating (OARS) and what it does** (the age limit in parental controls, T-211: planned), controller support (`<supports><control>gamepad`), the `x-ruya-*` keys (`x-ruya-hero`, `x-ruya-logo`, `x-ruya-launch-mode`, `x-ruya-controller`; and the **planned** `x-ruya-save-paths`/`x-ruya-cache-paths`), art sizes the Home and the Store use; a validated example and how to validate (`appstreamcli validate`).
3. **Controller input and the Guide button:** what an app receives today (evdev gamepads via the pad's own device in the sandbox; `ruya-inputd` is only the shell's navigation bridge: say what that means for games), SDL gamepad mapping example, hot-plug, keyboard/mouse fallback, the Guide button belongs to the console (the app never sees a "home" press; how the overlay appears over a running app: 02 §1.5), Steam Input (planned with InputPlumber, B-006). State honestly what is verified (the key-logging test client in the VM) and what is not.
4. **Full screen and lifecycle:** how the app is launched (the unit, the profile's user, `WAYLAND_DISPLAY` per-profile socket: planned T-164), full-screen is enforced by the compositor, the stop sequence (SIGTERM, 5 s, SIGKILL; reasons the player sees: quit, crashed, killed), suspend/resume (apps keep running), **sizes and the 10-foot UI** (safe area, text >= 24 px at 1080p/3 m, focus rules from 02 §4.3 and `04` §1), 720p/1080p/4K output.
5. **Permissions and sandbox rules:** the Flatpak `finish-args` games usually need (`--socket=wayland`, `--device=dri`, `--socket=pulseaudio` or the PipeWire route per ADR-010, `--share=network` only if needed), what the Store shows to players and which permissions are flagged "High risk" (`all-devices`, `host-files`, `session-bus`, spec 03 §4.4), what is refused, portals for user files.
6. **Audio and video:** how audio reaches the speakers (PipeWire in the shell's session; per-profile audio sockets: planned B-007), output following the default sink, codecs shipped (ADR-009), hardware video decode status, HDR/VRR (not yet).
7. **Testing and debugging:** the dev image and how to get one (`docs/dev-setup.md`), SSH with the dev key (test machines only), `journalctl` of your app's unit (`ruya-app-ruya-p<N>-<id>.service` and its `app-flatpak-<id>-*.scope`), `flatpak run --command=sh`, `flatpak kill`, simulating power loss and a stop (the checklist in saves-and-data), where profiles and data live; a table of common problems.
8. **Publishing:** the `ruyaos` remote and the review process (**planned**, spec 03 §4.6/Phase 7): what is decided (Flathub is also supported with the controller filter) and what is not; the review checklist a developer can self-check today (a markdown checklist reusing the saves, lifecycle and permission checklists).
9. **Sample game** `samples/hello-game/`: a tiny but real game (a small SDL2 game in C, or Python with pygame-ce if the runtime has it: pick what builds easiest on the chosen runtime and say why) with a Flatpak manifest, an AppStream file with every recommended key, SDL gamepad input with keyboard fallback, saves in `$XDG_DATA_HOME/saves/` written atomically with `.bak`, a SIGTERM handler that saves within the grace, a `README` with the build/run commands. Its licence: MIT or CC0 (say which; it is meant to be copied).
10. **Index and style:** update `README.md` (table statuses, quick facts) and keep every chapter in the same shape: short intro, rules, examples that run, a checklist, "planned" clearly marked.

## Out of scope
- The SDK/QML helper module (spec 03 §4.6, Phase 7), a documentation website or search, translations, API reference generation, publishing infrastructure, video tutorials.

## Acceptance criteria
- [ ] All chapters above exist, are linked from the README, and every factual claim can be traced to a spec section or the code (a short "Sources" footer per chapter listing the files/sections checked, with the date).
- [ ] `scripts/lint-dev-docs.ps1` (new, part of `dev.ps1 test`): every relative link in `docs/developers/` resolves; fenced `python` blocks parse (`ast.parse`), `sh`/`bash` blocks pass `bash -n`, `xml` blocks are well-formed (so the AppStream and manifest examples are valid XML/JSON/YAML); every chapter listed in the README exists; the self-check shows it failing on a broken-link fixture.
- [ ] The sample game builds with `flatpak-builder` into a local repo (the exact commands are in its README; paste the successful build output summary in the Outcome) and `appstreamcli validate` passes on its metainfo; the saves example in `saves-and-data.md` is the sample's code.
- [ ] VM (lead run): `scripts/vm-sample-check.sh` (copy `vm-session-check.sh`): install the sample into the guest, launch it through `Session1`, it writes a save under `~/.var/app/<id>/data/saves/`, `Stop` makes it save and exit within the grace (reason `quit`, not `killed`), a second launch loads the save, uninstalling with "keep data" keeps it; Outcome `Verified: host (vm pending: vm-sample-check.sh)`.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Docs to update
- `docs/developers/*`, `docs/specs/03-services-and-apps.md` §4.6 (point to the guide, mark what is built), `docs/dev-setup.md` (the new lint and the sample check), `README.md` of the repo (a "Build for RuyaOS" link).

## Hints
- Do not describe features that are not built as if they were; "planned (T-nnn)" is the honest word, and the README table is where the reader looks first.
- The best test of a guide: follow it from a clean WSL distribution; fix every step that does not work as written.
- Keep examples short; link to the sample for the full code.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
