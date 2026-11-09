# T-400 - Spike: where saves are, found as the profile user (agent, Ludusavi manifest, runner and Steam prefixes)

Status: todo · Phase: 5 · Depends: T-302 · Area: services, docs · Size: M · Owner: lead · Complexity: hard · Developer surface: internal

## Goal
The facts ADR-028 rests on: a working prototype that finds the saves of a Flatpak game, a game in our GE-Proton prefix and a Steam Proton game on the Dell, as the profile user, and hands a list (not a path into the home) to the root side.

## Read first
- `docs/specs/00-overview.md` ADR-020, ADR-023 (root services stay out of profile homes; 03 "Per-profile access to the profile's home"), ADR-025, ADR-028; `docs/specs/05-play-packages.md` §6 (prefix per game per profile); `docs/developers/saves-and-data.md`; T-215, T-309, T-381
- The proposal, `docs/archive/research/universal-game-and-save-management-proposal.md` §7-§9 (discovery, Windows, native)
- Upstream: the Ludusavi manifest (format, coverage, licence and where its data comes from)

## Scope
1. **The per-profile agent:** a user unit in each profile's manager (or the hub's per-profile half) that lists save candidates; how the hub and the shell reach it (the T-340 `systemd-stdio-bridge` route or a socket); its sandboxing.
2. **Sources:** XDG dirs of Flatpak apps (`~/.var/app/<id>/data`), our prefixes (`drive_c/users/<user>` minus caches), Steam Flatpak `compatdata/<appid>/pfx`, Heroic/Lutris Flatpak prefixes; map Windows variables (`%APPDATA%`, `Saved Games`) to paths.
3. **Ludusavi manifest:** does it cover what the Dell has; can we read it offline; its licence and its data's origin (an owner question if non-commercial terms apply).
4. **Snapshot cost:** size and time of a prefix-users snapshot for STK-sized and AAA-sized saves; dedup option (hard links or a content store).
5. Rewrite T-401..T-403 and T-309 with the facts.

## Acceptance criteria
- [ ] A spike report in this Outcome with commands and numbers from the Dell; the licence facts for the owner.
- [ ] ADR-028 updated; T-401..T-403, T-309 rewritten; `dev.ps1 docs` ALL GREEN.

## Outcome
_Filled in by the implementer._
