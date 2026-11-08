# RuyaOS developer guide

For people who make games and apps for RuyaOS, a living-room console OS: controller first, full screen, one Unix user per profile, Flatpak only. This guide says what to do, what the console does for you, and what is not available yet.

**Status of each chapter** (`written` = in this folder and checked against the code as of its date; `planned` = tracked in the backlog, do not rely on it yet):

| Chapter | Status | Backlog |
|---|---|---|
| [Getting started](getting-started.md): your first game as a Flatpak, built, installed on a RuyaOS dev machine and seen in the Games row | **written** (2026-11-06) | the Play button and the game window: T-147, T-164 |
| [AppStream metadata](appstream-metadata.md): name, art, categories, content rating (age), controller support, the `x-ruya-*` keys | **written** (2026-11-06) | age limits: T-211; `x-ruya-launch-mode`, `x-ruya-save-paths`: not read yet |
| [Controller input](controller-input.md): what your game receives, the Guide button, hot-plug, Steam Input | **written** (2026-11-06) | pad access for profile games, InputPlumber: B-006 |
| [Full screen and lifecycle](fullscreen-and-lifecycle.md): how your game starts, loses focus and stops; screens for the sofa | **written** (2026-11-06) | display for profile apps: T-164; quick menu: T-147; profile switch: T-165 |
| [Saves and data](saves-and-data.md): where to write saves, save states, settings and caches; atomic writes; what happens on SIGTERM; what the console backs up | **written** (2026-11-06) | backup and restore: T-215 |
| [Permissions and sandbox rules](permissions-and-sandbox.md): what the Store shows to players, what is high risk, portals | **written** (2026-11-06) | portal backend for file dialogs: not started |
| [What the console records about your game](play-time.md): the per-profile play history (times and the exit reason only), what counts as play time | **written** (2026-11-07) | parental limits: T-211; Steam's own play time: later |
| [Audio and video](audio-and-video.md): PipeWire, the pulse route, codecs, hardware decode, HDR/VRR (not yet) | **written** (2026-11-06) | audio for profile games: B-007 |
| [Sound themes](sound-themes.md): make the console's interface sounds and ambient bed; the theme folder, the cue list, the limits, trying one from a USB drive, the generator that makes the shipped theme (not about game audio) | **written** (2026-11-07) | listening check on a console: pending |
| [Testing and debugging](testing-and-debugging.md): the dev image (QEMU) and hardware, the dev SSH key, logs, how to break your game on purpose | **written** (2026-11-06) | |
| [Publishing](publishing.md): the routes today, the `ruyaos` remote and review (planned), a self-review checklist | **written** (2026-11-06); the remote and review: planned (Phase 7) | |
| [The public surface](api-surface.md): which parts of the console an app may rely on, the three tiers, how a public API is made, documented and versioned, the open-task audit | **written** (2026-11-08) as a **Proposed** charter (ADR-022); nothing in tier B can be called yet | the Platform service: T-352; API level: T-351 |
| [A sample game](../../samples/hello-game/README.md) (`samples/hello-game/`, CC0): follows every chapter, builds with `flatpak-builder` | **written** (2026-11-06) | VM check pending: `scripts/vm-sample-check.sh` |

**Read the status column first.** The console is in development: you can build, install, list, start (through the session service), stop and uninstall a game today, but **a game does not get a window, controllers or sound yet** when the console starts it for a profile (per-profile Wayland sockets T-164, InputPlumber B-006, audio B-007). Every chapter says what that means for you and how to test in the meantime. Each chapter ends with a "Sources" list of the code and specs it was checked against, with the date; `scripts\lint-dev-docs.ps1` (part of `dev.ps1 test`) checks the links, the code blocks and that footer.

Everything here is open source (docs: CC-BY-4.0). Found something wrong or missing? Open an issue or a pull request against `docs/developers/`.

## Quick facts

- **Format:** Flatpak only. The console installs apps system-wide; the **data is per profile** (each profile is a Unix user).
- **Run:** the shell starts your app as the profile's user in its own systemd unit, full screen (the window and Play are not built yet: see above). The Guide button is the player's way back; your app does not draw a home button.
- **Stop:** the console sends `SIGTERM`, waits **5 seconds**, then `SIGKILL`. Save and exit within that time.
- **Input:** controllers first; keyboard and mouse work too. Do not assume a keyboard.
- **Data:** `~/.var/app/<your-app-id>/` as seen by your app through the XDG variables (`$XDG_DATA_HOME`, `$XDG_CONFIG_HOME`, `$XDG_CACHE_HOME`). See [Saves and data](saves-and-data.md).
