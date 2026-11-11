# What the console records about your game

The console keeps a private play history for each profile, so a player can see how they play (the Activity pages in Settings) and, later, so a parent can set limits. This chapter says exactly what is recorded, so you know what you do and do not have to build yourself.

## What is recorded

For every run of your game, **only these facts**:

| Fact | What it is |
|---|---|
| App id and version | Your Flatpak id, and the version in your AppStream file when the run began (an update while the game runs does not start a new run) |
| Start and end | Unix seconds (UTC) |
| Foreground seconds | How long your game was the one in front, with the player there |
| Exit reason | `quit`, `crashed`, `killed`, `time-limit` or `bedtime` |

Nothing about what happens inside your game is recorded: no scores, levels, screenshots, frame rates, controller input or save files. Nothing is sent anywhere: the history stays on the console, in a file only the system can read, per profile (`/var/lib/ruya-session/usage/<profile>/`). Players see their own history only, and a profile's history is deleted with the profile. It is not part of the save backup.

## What counts as play time

Time counts only while **all** of these hold:

- the profile is the active one and not locked, and the console is not suspended;
- your game is the foreground app (several games can run; only the one in front counts);
- the player has used a button, key or pointer in the last 10 minutes (the first 10 minutes of silence still count; after that the time stops until the next input). Audio does not yet keep the clock running: a game that is only played by listening or watching, with no input, stops counting after 10 minutes (the screen saver task, T-202, will replace this with one idle clock that audio also feeds).

Durations come from the monotonic clock, so a clock change (the console sets its clock from the network) never changes them. The console saves a heartbeat every 30 seconds; if the console loses power or the service dies, the run ends at the last heartbeat. A run under 10 seconds is dropped (a crash at start-up leaves nothing). A run that ends because a parent's time limit or bedtime stopped it is recorded with the reason `time-limit` or `bedtime` (parental controls, T-211).

## What this means for you

- **Do not build your own play-time tracker for the console's sake.** The player already has one; yours would count differently and the two would disagree.
- **A launcher counts as one game.** If your app starts other games (a Steam-style launcher), the time counts for your launcher; the console cannot see inside it (reading the launcher's own play time is planned).
- **Exit cleanly.** A `SIGTERM` that you answer with exit status 0 within 5 seconds is a `quit`; a crash is a `crashed` and shows up in the player's history as such. See [Full screen and lifecycle](fullscreen-and-lifecycle.md).
- **Pause when you lose focus.** Time stops counting when your game is no longer in front, and while Ruya Hub is open over it, so a game that keeps running in the background is not "played". (By default the console also freezes a game under the Hub or behind Home: [Full screen and lifecycle](fullscreen-and-lifecycle.md).)

## Sources

Checked on 2026-11-07 against: `api/dbus/org.ruyaos.Session1.xml` (ledger records, `ReportPresence`, `ListSessions`, `GetTotals`, `ClearHistory`); `services/ruya-session/src/usage_tracker.rs` (accounting rules and tests), `usage.rs` (retention, caps), `usage_store.rs` (files); `shell/qml/UsagePresence.qml` (what the shell reports, and the 10-minute idle rule); `docs/specs/03-services-and-apps.md` section 4.1; task files T-247, T-211, T-202, T-220, T-224.
