# RuyaOS developer guide

For people who make games and apps for RuyaOS, a living-room console OS: controller first, full screen, one Unix user per profile, Flatpak only. This guide says what to do, what the console does for you, and what is not available yet.

**Status of each chapter** (`written` = in this folder and checked against the code as of its date; `planned` = tracked in the backlog, do not rely on it yet):

| Chapter | Status | Backlog |
|---|---|---|
| [Saves and data](saves-and-data.md): where to write saves, save states, settings and caches; atomic writes; what happens on SIGTERM; what the console backs up | **written** (2026-11-06) | backup and restore: T-215 |
| Getting started: your first game as a Flatpak, run on a RuyaOS dev machine | planned | T-214 |
| AppStream metadata: name, art, categories, content rating (age), controller support, the `x-ruya-*` keys | planned | T-214 |
| Controller input: what your app receives, the Guide button, hot-plug, Steam Input | planned | T-214 |
| Full screen, lifecycle, suspend and the Guide overlay: how your app starts, loses focus and stops | planned | T-214 |
| Permissions and sandbox rules (what the Store shows to players, what is refused) | planned | T-214 |
| Audio and video: the PipeWire output, HDR/VRR (not yet), hardware decode | planned | T-214 |
| Testing on the dev image (QEMU) and on hardware; the dev SSH key; logs | planned | T-214 |
| Publishing: the `ruyaos` remote and review | planned (Phase 7) | T-214 |
| A sample game (`samples/`) that follows every chapter | planned | T-214 |

Everything here is open source (docs: CC-BY-4.0). Found something wrong or missing? Open an issue or a pull request against `docs/developers/`.

## Quick facts

- **Format:** Flatpak only. The console installs apps system-wide; the **data is per profile** (each profile is a Unix user).
- **Run:** the shell starts your app as the profile's user in its own systemd unit, full screen. The Guide button is the player's way back; your app does not draw a home button.
- **Stop:** the console sends `SIGTERM`, waits **5 seconds**, then `SIGKILL`. Save and exit within that time.
- **Input:** controllers first; keyboard and mouse work too. Do not assume a keyboard.
- **Data:** `~/.var/app/<your-app-id>/` as seen by your app through the XDG variables (`$XDG_DATA_HOME`, `$XDG_CONFIG_HOME`, `$XDG_CACHE_HOME`). See [Saves and data](saves-and-data.md).
