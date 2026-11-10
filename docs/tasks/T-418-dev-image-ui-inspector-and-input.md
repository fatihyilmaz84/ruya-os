# T-418 - Development images: inspect a running app's UI as data, drive it with a virtual pad, collect its logs

Status: todo · Phase: 7 · Depends: T-416, T-367, T-396, T-425 · Area: image (dev variant only), services (input service virtual pads), tools/ruya (`app run|logs|inspect-ui|input`) · Size: M · Owner: builder · Complexity: complex · Developer surface: public-API

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Needs the development image variant that T-425 defines (today there is one image) and ADR-027's action names from T-396. Add a criterion: on a release image the inspector socket and the input-injection method do not exist (a runtime refusal test, not only a manifest check).

## Goal
In the VM or a development image, `ruya app run`, `ruya app inspect-ui --format json` (screen, elements with role, name, focus, enabled), `ruya app input down,down,confirm` and `ruya app logs` let an agent check focus and navigation without a TV or a pad. Production images contain none of it.

## Read first
- ADR-031, ADR-024 (virtual pads by the input service), ADR-022 (stability), `scripts/vm-inject-key.py`, `scripts/vm-key-client.qml`, `scripts/vm-screenshot.ps1` (what exists for our own tests), `docs/developers/testing-and-debugging.md`, `image/CLAUDE.md`

## Scope
1. A dev-only socket service that reads the Qt accessibility tree of the focused app (the profile's session) and returns it as JSON; it is not installed in production images (a build flag and a check in `check-image-manifest.sh`).
2. Input: a dev-only virtual pad through the input service; key names match the action names of ADR-027.
3. Logs of the app's unit and screenshots of its surface; all three in `ruya app ...`.

## Acceptance criteria
- [ ] Tests: the tree of the sample app has the expected elements and focus moves after `input down`; production image manifest has no dev service (check red if it does).
- [ ] VM (this task): `vm-devtools-check.sh` runs the sample through all four commands; `RUYA_BOOT_OK`.
- [ ] `ruya-api-reviewer` and `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
