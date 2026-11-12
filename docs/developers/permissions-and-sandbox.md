# Permissions and sandbox rules

Your game runs in a Flatpak sandbox as the profile's own Unix user. What it may touch is what you list in the manifest's `finish-args`, and **the player sees that list in plain words before installing**. Ask for as little as possible: every extra line is a reason not to install, and some lines make a Standard profile ask for a parent's PIN.

*Checked against the code as of 2026-11-06. Items marked **planned** are not built yet.*

## What games usually need

```json
{
  "finish-args": [
    "--socket=wayland",
    "--device=dri",
    "--device=input",
    "--socket=pulseaudio"
  ]
}
```

| Flag | Why | What the player is told |
|---|---|---|
| `--socket=wayland` | draw to the screen | nothing (not listed) |
| `--device=dri` | the GPU (OpenGL, Vulkan) | nothing |
| `--device=input` | game controllers (`/dev/input`); needs Flatpak 1.18 as in Fedora 44, older ones only know `--device=all` | "Uses game controllers" |
| `--socket=pulseaudio` | sound; this is the route RuyaOS provides for audio ([Audio and video](audio-and-video.md)) | "Plays sound" |
| `--share=network` | online play, downloads, cloud saves of your own. **Only if you need it** | "Uses the network" |

Use `--socket=wayland`. An X11-only game (`--socket=x11` or `--socket=fallback-x11` and no `--socket=wayland`) runs on a private X server of its own (*experimental*, [fullscreen-and-lifecycle.md](fullscreen-and-lifecycle.md)); do not add X11 next to Wayland, the console never uses it then. Do not add `--share=ipc` unless a library demands it.

## What the Store shows, and what is "High risk"

The Store reads your app's metadata and lists these, in this order (`ruya-store`, `shell/qml/AppDetailPage.qml`):

| Your `finish-args` | Listed as | Risk |
|---|---|---|
| `--share=network` | "Uses the network" | |
| `--filesystem=home`, `--filesystem=~...`, `--filesystem=xdg-documents`, `xdg-download` and the other `xdg-*` | "Reads and writes files in your home folder" | |
| `--filesystem=host`, `host-os`, `host-etc`, or any absolute path | "Reads and writes all files on this device" | **High risk** |
| `--device=all` | "Accesses all devices" | **High risk** |
| `--socket=pulseaudio` | "Plays sound" | |
| `--device=input` | "Uses game controllers" | |
| `--socket=session-bus`, or `--talk-name=org.freedesktop.Flatpak` (also `--own-name`) | "Can control other programs on this device" | **High risk** |

Everything not in the table (Wayland, DRI, `--share=ipc`, `--talk-name=` for other names, ...) is not shown. Entries you remove with `!` or `--no...` grant nothing and are not listed.

**High risk** means a warning badge and warning-coloured text on the app page. For a **Standard profile**, installing the app, and updating it when the update *adds* a high-risk permission, asks for an **admin's PIN** first; admins install directly. An update that only adds harmless permissions starts at once, and the page says "The update adds: ..." so nobody is surprised. In short: **do not use `--device=all`, `--filesystem=host` or `--talk-name=org.freedesktop.Flatpak`**; none of them is needed for a game. `--device=all` is the lazy way to get controllers, `--device=input` is the right one.

## What the console refuses and what it does not

- **Refused:** an app from a remote whose signature does not verify (the Store reports `signature`), and an unsigned remote at all: `AddRemote` never passes `--no-gpg-verify`, and removes a remote that ended up unsigned. Publishing needs a signed repository ([Publishing](publishing.md)).
- **Never allowed by the platform:** third-party apps outside Flatpak, apps run as root or as the shell's user, and anything that starts by itself from removable media. These are not options in the manifest; they are the console's rules.
- **Not refused:** a permission is never *refused* by the console in v1; it is shown and, if high risk, gated by the PIN. The review you will go through when you publish (**planned**, Flathub-style, see [Publishing](publishing.md)) is where an unreasonable list gets questioned.
- **Planned:** admins reviewing and overriding an app's permissions one by one (a Flatseal-like view, spec 03 section 4.4). Not built.

## Files: use the data directory and portals

- Your own data goes in `$XDG_DATA_HOME`, `$XDG_CONFIG_HOME` and `$XDG_CACHE_HOME` and needs **no permission** ([Saves and data](saves-and-data.md)). Never ask for `--filesystem=home` to store saves.
- A file the *player* chooses (a ROM, a mod, a picture) is meant to go through the **file chooser portal**: the sandbox gets the one file the player picked, with no permission in the manifest. **The portal backend that draws such dialogs in the shell, controller-navigable, is not built yet** (spec 03 section 4.4, "Gap to spike"). Until it exists, do not depend on a file chooser; read from a folder inside your data directory, or from removable media (media access for Flatpak apps is left to the Media work) and say so in your README.
- Removable media never auto-runs anything.

## The rest of the sandbox

- The profile's home is private (mode 0700): other profiles and the administrator cannot read your game's data; only the console's services can.
- Your game cannot start other programs on the host, see other apps' data, or change the system. The runtime and your `/app` are read-only.

## Check what you have

```sh
flatpak info --show-permissions org.example.MyGame
flatpak run --command=sh org.example.MyGame
```

The first prints your final permissions as Flatpak sees them (the Store derives its list from the same data). The second opens a shell inside the sandbox to see what is visible.

## Checklist

- [ ] The permission list contains only what the game needs (`wayland`, `dri`, `input`, `pulseaudio`, and `network` if you go online).
- [ ] No `--device=all`, `--filesystem=host` (or `host-os`, `host-etc`, absolute paths), `--socket=session-bus` or `--talk-name=org.freedesktop.Flatpak`.
- [ ] No `--filesystem=home` and no `xdg-*` filesystem access for saves.
- [ ] Network is requested only if the game uses it, and you can say what for.
- [ ] `--socket=wayland`, or X11 only if the game cannot do Wayland.
- [ ] An update does not add a permission without a reason; if it must, your release notes say why.

## Sources

Checked on 2026-11-06 against: `services/ruya-store/src/appstream.rs` (`permissions()`: which flags map to which key, negated entries ignored); `shell/qml/AppDetailPage.qml` (`highRisk`, the texts); `docs/specs/03-services-and-apps.md` sections 4.2, 4.4 (as built T-111, T-152, T-156); root `CLAUDE.md` (security invariants); `docs/specs/00-overview.md` ADR-002, ADR-004; `man flatpak-build-finish` (Flatpak 1.18.4); `samples/hello-game/org.ruyaos.HelloGame.json`; `flatpak info --show-permissions` run on the sample.
