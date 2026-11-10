# T-444 - The default store (`ruyaos`): hosting, key, submissions, curated entries: decisions, then the tasks

Status: blocked (owner: hosting, signing-key custody, who may submit; ADR-032 open point 1) · Phase: 7 · Depends: owner, T-381 · Area: docs · Size: S · Owner: lead · Developer surface: public-format

## Goal
The store the console ships with exists on paper precisely enough to build: where it is hosted, who holds its key, how an app gets in, how our curated entries for Flathub apps work, and what the image carries. Today `03` §4.2 names it and nothing exists. This task writes the decisions into `docs/specs/10-stores.md` and the build tasks; it builds nothing.

## Read first
- `docs/specs/10-stores.md`, ADR-032; `docs/developers/publishing.md` ("Not decided yet"); `03` §4.6
- T-381's Outcome (the runner needs this remote first), T-252 (the app template publishes to it), T-426 item 1 (key custody for the image; the same people and rules should hold this key)

## Scope
1. Put to the owner, with options and a recommendation each: hosting (static files on an object store or pages host; cost), key custody (who signs, where the key lives, rotation and the lost-key plan; never in the repository, the image or CI logs), who may submit and the review bar (the self-review checklist of `publishing.md` as the first bar), whether unreviewed apps go to Flathub or a third-party store instead (recommended: yes, that is what ADR-032 is for).
2. Decide (lead): the repository layout and the manifest repository, how a build is produced and signed (reproducible from the manifest), how the image carries the remote and its key (like `ruya-flathub-remote.service`), the curated-entry mechanism for Flathub apps (art and controller tags: an AppStream overlay the service merges, never a rebuilt app).
3. Edge cases to answer in the spec: the official store is unreachable at first boot (the console works, Flathub works); the key must be rotated (the new key arrives with an OS update, both valid for a period); an app is withdrawn (installed copies stay, marked); an official app and a Flathub app share an id (official wins, `10-stores.md` §3).
4. Write the build tasks (the remote in the image; the build and sign pipeline; the overlay) and mark T-252 and T-382 with what they can now rely on.

## Out of scope
- Building or publishing anything; payments; a developer programme.

## Acceptance criteria
- [ ] `10-stores.md` has a section "The official store" with each point of scope 1 and 2 marked decided (who, date) or open with its STATUS entry.
- [ ] The build task files exist, pass the quality bar and are on the board; T-252 and T-382 name them.
- [ ] `.\scripts\dev.ps1 docs` green.

## Verification
```powershell
.\scripts\dev.ps1 docs
```

## Docs to update
- `docs/specs/10-stores.md`, `docs/developers/publishing.md`, STATUS open decisions.

## Outcome
_Filled in by the implementer. First line: `Verified: host` (documents only)._
