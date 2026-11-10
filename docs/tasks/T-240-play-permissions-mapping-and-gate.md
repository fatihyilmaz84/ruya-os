# T-240 — Permissions: manifest vocabulary to Flatpak, ceilings, admin gate

Status: todo · Phase: 7 · Depends: T-231, T-238 · Area: services, shell · Size: M · Owner: builder

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** Overrides go through `ruya-store`'s override mechanism from T-220, not a second one in `ruya-play`.

## Goal
What a package asks for is shown in plain words, capped by how far it is trusted, mapped to exactly the Flatpak permission set it gets, and gated by the admin PIN when high-risk, reusing the Store's flow. A package can never obtain a permission the vocabulary does not name.

## Read first
- `docs/specs/05-play-packages.md` §8 (the table is the contract); `docs/specs/03-services-and-apps.md` §4.4 (words, high-risk gate, "update adds"); `docs/developers/permissions-and-sandbox.md`
- `services/ruya-store` appstream permission reading (`added_permissions`) and the shell's permission wording (`AppDetailPage.qml`)

## Scope
1. A pure mapping module (in the format crate or `ruya-play` core): vocabulary -> Flatpak args/metadata, plain-word strings (English keys, Turkish in the shell), risk level, ceiling by tier. A table in code mirrors the table in spec 05 (a test parses the spec table and compares).
2. The generated Flatpak metadata in T-238's commit uses it; the manifest never contributes raw Flatpak keys; a manifest with an unknown permission is invalid already in T-230 (cross-checked here).
3. Permission **diff** for updates (used by T-241): added/removed permissions between installed and new, high-risk detection.
4. Shell: the package page and the app's detail page show the words and risk markers from the service (`Inspect` result), the admin gate for Standard profiles uses the existing PIN flow; an admin can reduce permissions per app (Flatseal-like view, 03 §4.4): minimal version that stores overrides as Flatpak overrides through `ruya-play` and shows "Reduced by an admin".
5. Resource limits on the running scope (05 §8 last bullet): memory and tasks maximum from `requirements`, never above 90 % of RAM; applied by `ruya-session`'s spawner or by the unit properties it already sets (check `systemd.rs`).

## Out of scope
- New vocabulary items beyond 05 §8, bus-name access, filesystem paths, Proton-specific needs.

## Acceptance criteria
- [ ] Table test: every row of the 05 §8 table maps to the documented Flatpak argument and risk; a test parses the spec markdown table and fails if code and spec disagree (`tests/permissions_spec_sync.rs`).
- [ ] For each trust tier, each permission: allowed, gated or refused as the ceiling table says (`tests/ceilings.rs`, generated from the table).
- [ ] The generated metadata for the Wine fixture contains exactly the expected set and nothing else (`tests/metadata.rs`, exact string comparison); a fixture trying to smuggle `filesystem=host` through `env`, `reasons` or a field name gets nothing extra.
- [ ] Diff: update adding `network` shows it; adding `devel` marks high-risk (`tests/diff.rs`).
- [ ] Shell tests: words and markers for every fixture, admin gate for Standard, direct install for admin, override view reduces and labels (`tst_playperms.qml`); screenshots English/Turkish.
- [ ] VM (lead run): `vm-play-check.sh perms`: the installed fixture's `flatpak info --show-permissions` equals the expected set; a reduced override takes effect at next launch (network off: a connection attempt from the payload fails); the memory limit kills a leak test payload without taking the shell down.
- [ ] `dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
.\scripts\dev.ps1 shots
```

## Docs to update
- Spec 05 §8 as built; spec 03 §4.4 gets a line for `.play`.

## Outcome
_Filled in by the implementer._
