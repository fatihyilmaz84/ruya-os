# Platform Demo

The smallest app that uses the console's lifecycle events, `org.ruyaos.Platform1.Lifecycle` (experimental, [Full screen and lifecycle](../../docs/developers/fullscreen-and-lifecycle.md#lifecycle-events-experimental)), and a test that runs it off the console against the developer mock ([Testing and debugging](../../docs/developers/testing-and-debugging.md#testing-the-platform-api-off-the-console)). It has no window: it prints what it does.

| What the guide asks | Where it is here |
|---|---|
| Detect a freeze from the clock first, clamp the time step | `main` (the `gap` and `dt` lines) |
| `Register` once, after start, with the signal match set up first | `lifecycle_register` |
| Run on when there is no service, no bus or no permission | `lifecycle_register` (every path that returns `NULL`) |
| `Resume(frozen_ms)`, `Background` | `on_lifecycle` |
| `Stopping`: save, `fsync`, then `SaveDone` | `on_lifecycle`, `save_game`, `lifecycle_save_done` |
| `SIGTERM` saves and exits 0 | `on_term`, end of `main` |

## Licence

CC0 1.0 (public domain, SPDX `CC0-1.0`): copy any file, change it, ship it, no attribution needed. See `LICENSE`.

## Build and test

On Linux, with a C compiler, `pkg-config`, sd-bus (`systemd-devel` on Fedora, `libsystemd-dev` on Debian and Ubuntu) and `dbus-run-session` (`dbus-daemon`). The test needs the mock from this repository, built once:

```sh
(cd ../../services && cargo build -p ruya-platform --bin ruya-platform-mock)
make test
```

`make test` runs the demo with no Platform service (it must say so and run on), then starts the mock on a private bus with `tests/scenario.json`, and checks a clock gap, `Resume(1500)` and a `Stopping` answered with a save and `SaveDone` (the mock answers `saved`). Another mock: `RUYA_PLATFORM_MOCK=<path> make test`.
