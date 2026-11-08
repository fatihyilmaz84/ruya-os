# T-256 — First-party app: File manager

Status: todo · Phase: 7 · Depends: T-251, T-252 · Area: apps · Size: M · Owner: builder · Developer surface: none

## Goal
A controller-first file manager: browse the console's storage and USB drives, copy, move, rename, delete, see free space, safely. It also provides the folder-browser component that the picture viewer and the media player reuse. Part of T-248; its own Flatpak (`org.ruyaos.Files`).

## Read first
- T-248, `docs/specs/06-hig.md`, the app template (T-252), the Storage service interface (`Devices1` storage part: volumes, mount, eject, free space, `/run/media/ruya-shell/...` mounts), T-215 (saves backup: do not collide), T-221 (app management), `docs/developers/permissions-and-sandbox.md`, the security invariants in `CLAUDE.md` (nothing auto-runs from removable media)

## Scope
1. **What the sandbox may see (decide and record):** the profile's own data and the media mounts through the portal or a narrow `--filesystem` grant; not `/`, not other profiles' homes, not `/var/lib/flatpak` or system paths. A permission request that cannot be justified is not asked.
2. **Browse:** places (this console, each mounted drive with name, size, free), folders and files as a list or grid with icon, size, date; sort and filter; a path bar; hidden files off by default; a details panel; large folders load in the background without blocking focus.
3. **Operations:** select (A holds, X for the menu), copy and move between places with a progress view and cancel, rename (on-screen keyboard), new folder, delete (a confirmation that names the item; a trash for the console's own storage, none on drives), eject a drive when no operation uses it, an error in plain words when a drive is read-only, full or removed mid-copy; operations survive a profile lock only per the platform rules (stop cleanly otherwise).
4. **Safety:** files from a drive are data only: never opened with the default handler automatically, no execution of anything (no "run" action; `.desktop`, scripts and `.flatpakref` files are shown, not run: installing is the Store's job), symlinks are shown as links and never followed out of the permitted root, names are shown as plain text with control characters stripped, case and length limits respected on FAT/exFAT/NTFS names, no operation on the system's own paths.
5. **Opening files:** hands pictures to the picture viewer, audio and video to the player when installed, otherwise "no app for this file" with the Store suggestion (the Store's search is not built here).
6. The reusable **folder browser** component lives in RuyaKit's app-side additions or the template, as T-250 decides. Turkish and English, accessible names.

## Out of scope
- Network shares and cloud drives, archives and compression, formatting a drive (the Storage pane owns it), file search across drives, tags.

## Acceptance criteria
- [ ] Tests (fake file system): navigation and focus, sorting, selection, copy, move and cancel with progress, rename and delete with confirmations, symlink escape refused, hostile names, read-only and full drives, eject blocked while busy, controller-only operation.
- [ ] No code path executes or auto-opens a file from a drive (a test greps the app for launch calls and asserts the handler list is the allowed set).
- [ ] Screenshots (English and Turkish) against `04` §8 and the HIG checklist.
- [ ] Builds as a Flatpak from the template; VM (lead run): copy a file to and from a real mounted stick and eject it. `.\scripts\dev.ps1 test` green.

## Hints
- Developer surface (ADR-022, `docs/developers/api-surface.md`): none. Dogfooding rule: this app may use only the public surface; if it needs something else, add an Inbox line proposing the capability, do not use a private service.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified`._
