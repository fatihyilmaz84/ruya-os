# T-245 — Notification centre: history, quiet mode, and notifications from apps

Status: todo · Phase: 2 · Depends: — · Area: api, services, shell · Size: M · Owner: lead

## Goal
Every notification the console shows is kept, can be read later and can be controlled (owner request, 2026-11-07; Xbox, PlayStation, Steam TV mode and Android TV all have one). Today toasts are ephemeral (`Notifications` singleton: drive inserted, controller battery low, the sticky update restart notice, the heat notice, app crashed...): look away and it is gone, and apps cannot notify at all. Owner: lead because it adds a service and a bus bridge.

## Read first
- `docs/specs/02-shell.md` (toasts, Guide overlay, Settings), `03-services-and-apps.md` (`ruya-session`, profile managers, bus policies), `04-design-system.md` §8; `shell/qml/Notifications.qml` and its callers; `services/CLAUDE.md`, `shell/PATTERNS.md`
- T-223 (the status cluster the bell sits in), T-202 (screen saver, sleep), T-213 (time zone), T-211 (parental controls: leave a policy hook only), T-227 (sounds), T-147 (fullscreen apps), `docs/developers/` (chapter layout and lint)

## Scope
1. **Centre (shell):** opened from the Guide overlay ("Notifications") and from a bell with an unread badge in the top status cluster (next to the T-223 chips). A glass panel/page listing the active profile's last 50 notifications, kept 7 days: icon (source/kind), title, one line of text, time ("2 min ago"), an unread dot, and the actions the source gave ("Restart now", "Open Settings", "Open"). A runs the action and clears the item; X/Y or the menu key clears one; "Clear all" at the top; an empty state in plain words. Sticky or important items (the update restart notice, thermal critical) stay pinned on top until resolved. Controller-first, focus asserted, Turkish.
2. **Quiet mode:** a switch in the Guide overlay and in Settings -> Notifications. On: toasts and sounds are suppressed, everything still lands in the centre with the badge. **"Don't interrupt games" (default on):** while a fullscreen app runs, only critical items (thermal critical, an imminent update restart, low battery of the only controller) break through as a small corner toast. Optional schedule (from/to, local time from T-213). State how it interacts with the screen saver and sleep (T-202).
3. **Settings -> Notifications:** per-source switches (System, Updates, Devices (drives, batteries), Store and downloads, and each app that has sent one), toast duration, sound on/off (the UI sounds channel), "Clear history".
4. **One model:** the shell's own sources and the services (update, devices, store) use the same entry point, so the centre is the single list. The existing toasts become views of it.
5. **Apps (decide and record in the Outcome):** Flatpak apps notify through the freedesktop Notification portal / `org.freedesktop.Notifications` on their own profile user session bus, which the shell (`ruya-shell`) cannot see. Add a bridge in a root or session service (candidate: `ruya-session`, which manages profile apps and managers, or a tiny per-profile helper unit it starts) that implements the notification server on each profile user's bus and forwards to the shell through a new system-bus interface `org.ruyaos.Notifications1`: `Notify(profile, app_id, title, body, icon, actions, urgency) -> id`, `Close`, `ActionInvoked(id, action)` back to the app, `NotificationClosed`. Contract first (`api/dbus/`, mock, D-Bus client). Only the active profile's notifications reach the shell (others are queued or dropped: decide and write it down). Limits: rate, size, plain text only (no markup/HTML), icons by name or a small validated image. A profile's history is private to that profile and stored by the service per profile, not in the shell. A policy check hook for T-211 (parental controls), nothing built.
6. **Docs:** a "Notifications" chapter in `docs/developers/` (how a Flatpak game sends one, what the console does with it; status "planned" until built, then updated), `02`, `03`, the XML, `dev-setup.md`.

## Out of scope
- Push or remote notifications, email or social integration, grouping beyond per source, rich media in notifications, a developer SDK.

## Acceptance criteria
- [ ] Rust tests (bridge core, with fakes): limits, sanitising, profile privacy, the action round trip, history size and age caps, the active-profile rule.
- [ ] QML tests (mock): badge counts, list order and pinning, actions run, clear one and all, quiet mode and "don't interrupt games" including the critical break-through, per-source switches, focus asserted, controller-only operation, late-reply guard.
- [ ] Screenshots (English and Turkish) read against `04` §8.
- [ ] VM (lead run): a Flatpak test app sends a notification as a profile user; it appears in that profile's centre only; an action comes back to the app; quiet mode suppresses the toast but keeps the item. `scripts/vm-notify-check.sh`.
- [ ] `lint-dev-docs.ps1` passes for the new chapter; `.\scripts\dev.ps1 test` and `shots` ALL GREEN.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
