# T-468 — Developer docs: the Hub pauses (freezes) your game

Status: todo · Phase: 2 · Depends: — · Area: docs (developers) · Size: S · Owner: builder · Complexity: normal · Developer surface: public-format

## Goal
A developer making a game for RuyaOS knows exactly what happens to it when the player opens the Ruya Hub, goes Home or switches to another game, and what to do about it. Today `docs/developers/fullscreen-and-lifecycle.md` (lines ~34-40) still describes the old overlay ("keep running behind the overlay, pause when you lose focus"; the quick menu "planned"), while since T-457 the Hub **freezes** the game's processes (cgroup freezer) and Home leaves it frozen (ADR-033, `02` §1.6).

## Scope
1. **Find out, don't assume** (code, then the VM over SSH where the code cannot say): before the freeze, does the game get anything (Wayland keyboard leave / focus out, `xdg_toplevel` state, frame callbacks stopping)? While frozen: timers, sockets (a peer may time out), audio (silent; T-466 will detach the stream), memory (T-465/T-466: may be swapped out after about 30 s). After the thaw: what arrives first (focus in, a frame callback), the time jump (CLOCK_MONOTONIC keeps running), how long Thaw takes (Dell study: about 200 ms).
2. Rewrite the section "The Guide button and the Hub" (or the current overlay section) in `fullscreen-and-lifecycle.md`: what the player sees, what your process experiences, and what to do (clamp frame time after a long gap; pause gameplay on focus loss if the console sends it, else on the time jump; reconnect or tolerate a dropped network peer; save at safe points, since a frozen game cannot react to Close).
3. Update the checklist at the end, the samples if one pauses on focus loss, and `api-surface.md` if it lists the overlay.
4. Mark anything not yet built as planned with its task (T-465, T-466), as the guide does elsewhere.

## Acceptance criteria
- [ ] Every statement about frozen behaviour cites what was checked (code path or VM run) in the Outcome
- [ ] `dev.ps1 docs` ALL GREEN (developer guide lint)
- [ ] `ruya-api-reviewer` at merge (Developer surface: public-format)

## Hints
- Planned by lead-11 on the owner's question. The Close path (thaw, then SIGTERM, grace, kill: T-457, T-458) belongs in the same page's "Stopping" section: check it is still right.

- Since T-467 every Session1 game is frozen by the Hub, including pygame/SDL ones whose window Session1 cannot map (before, those kept running under the Hub).

## Outcome
_Filled in by the implementer._
