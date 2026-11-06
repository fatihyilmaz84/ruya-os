# Publishing

How your game gets from your build to players' consoles. **Honest summary: there is no public publishing route yet.** The official `ruyaos` remote and its review process are planned for Phase 7 ("Ecosystem"); what exists today is the Flatpak machinery they will sit on, and Flathub, which the console can already use. This chapter says what is decided, what is not, and gives you a checklist you can run on your game now so that review will be a formality.

*Checked against the code and specs as of 2026-11-06. Items marked **planned** are not built yet.*

## The routes

| Route | What it is | Status |
|---|---|---|
| **Your own repository** (a Flatpak repo you sign and host) | Test builds for players and testers: an administrator adds it as a *developer remote*; its apps carry a red "Developer" badge | the Store service supports signed remotes (`AddRemote`); **no screen for it yet**, use `flatpak remote-add` over SSH |
| **Flathub** | The big community repository. The console has it as the *Community* source, on, with a controller filter: the Store hides apps without `<control>gamepad</control>` or an `x-ruya-controller` value of `full` or `partial`, unless the player turns on "Show all apps" | **built** (T-140, T-148) |
| **The `ruyaos` remote** (Official, our key) | Our apps and curated entries, including *metadata overrides for Flathub apps* (art, controller tags). Publishing is a pull request to its manifest repository, reviewed Flathub-style | **planned**, Phase 7. The remote does not exist yet |

Decided (spec 03 section 4.2, ADR-005): Flatpak is the only format; sources are Official (ours, signed), Community (Flathub) and Developer remotes (off by default, an admin enables, red badge); **unsigned remotes are refused**; every app page shows its source. A separate "bundle" format is deferred and, if it ever comes, will be a Flatpak plus art.

**Not decided yet:** who may submit to the official remote, the exact review criteria, signing and key custody, how updates are announced, revenue or payments (none exist), and a public developer programme (listed as "later" in the scope, spec 00). Do not build plans on any of these.

## What to do today

1. **Make your game follow this guide.** Everything the review is likely to ask is in the chapters; the checklist below pulls it together.
2. **Publish on Flathub if you want players today**, following Flathub's own submission rules (their documentation is authoritative; RuyaOS does not change them). Make sure the AppStream file carries `<control>gamepad</control>` and ideally `x-ruya-controller`, the content rating and the art ([AppStream metadata](appstream-metadata.md)), so the console's Store does not filter you out.
3. **For testers**, host a signed Flatpak repository (`flatpak build-sign` or `--gpg-sign` when you export; give testers the `.flatpakrepo` file with your key). On a dev machine over SSH: `flatpak remote-add --system <name> <your.flatpakrepo>`. The console's Store refuses a remote without a valid key.
4. **Tell us what is missing.** Open an issue on the repository: the review rules are not written because nobody has submitted a game yet.

## Self-review checklist

Run this before you ask anyone to look at your game. It reuses the checklists of the other chapters; tick each box in your own notes.

**Package**

- [ ] The Flatpak builds from source with `flatpak-builder` from a clean checkout ([Getting started](getting-started.md)).
- [ ] `appstreamcli validate` passes; the app id, desktop entry and metainfo agree; `Categories=Game;` in the desktop entry.
- [ ] Open-source licence or a clear redistribution licence for everything in the package; the licence is in the AppStream file.
- [ ] No private keys, tokens or personal data in the package.

**Metadata**

- [ ] Name, summary and description in English; `<content_rating>` present and honest.
- [ ] `<control>gamepad</control>` and `x-ruya-controller` say what is true.
- [ ] Hero (16:9, 1920 px or more), card picture and icon exist ([AppStream metadata](appstream-metadata.md)).

**Behaviour**

- [ ] Plays full screen at 720p, 1080p and 4K with a controller only; text is 24 px or more at 1080p; everything inside the safe area ([Full screen and lifecycle](fullscreen-and-lifecycle.md)).
- [ ] The Guide button is unused; Esc and B do not quit; hot-plug works ([Controller input](controller-input.md)).
- [ ] The game pauses when it loses focus, saves and exits within the 5 seconds on `SIGTERM`, exits 0.
- [ ] Saves in `$XDG_DATA_HOME`, atomic with a `.bak`, rebuildable data in the cache; a killed game loses at most the last unsaved moment ([Saves and data](saves-and-data.md)).
- [ ] Starts and plays with no audio device and no network, unless the game is online-only and says so.

**Permissions**

- [ ] Only `wayland`, `dri`, `input`, `pulseaudio` (and `network` if used); none of the high-risk ones ([Permissions](permissions-and-sandbox.md)).

**Tested** ([Testing and debugging](testing-and-debugging.md))

- [ ] Launched and stopped through `Session1` on a dev machine, for a profile, with reason `quit`.
- [ ] Killed during a save; damaged newest save; uninstall with data kept.

## Sources

Checked on 2026-11-06 against: `docs/specs/03-services-and-apps.md` sections 4.1, 4.2, 4.3 (`AddRemote` as built), 4.6; `docs/specs/00-overview.md` (scope, "Later / stretch", ADR-005, the roadmap row for Phase 7); `services/ruya-store/src/` (a remote's `source` mapping; `AddRemote` never uses `--no-gpg-verify`); `docs/STATUS.md` (no remote UI in the shell, spec 03 4.3 "its D-Bus client does not call `ListRemotes` or `AddRemote` yet"). The self-review items are the checklists of the other chapters; nothing here has been exercised against a real review because none exists.
