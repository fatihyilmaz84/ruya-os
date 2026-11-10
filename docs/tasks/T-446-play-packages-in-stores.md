# T-446 - `.play` packages in a store: the signed index, one catalogue, install and update through the importer

Status: todo · Phase: 7 · Depends: T-441, T-231, T-234, T-238, T-388 · Area: api, services (ruya-store, ruya-play), shell (client, mock), tools (ruya-pack) · Size: M (split before dispatch: index and catalogue; install and update hand-over) · Owner: builder · Complexity: hard · Developer surface: public-format

## Goal
A store can offer `.play` packages next to, or instead of, Flatpaks: the console reads the store's signed index, shows the packages in the same Store with the same badges, downloads one and gives it to the `.play` importer, and later updates it from the same store. `docs/specs/10-stores.md` §11; ADR-032 point 6; waits for the `.play` epic (T-228, parked by the owner).

**Written early on purpose** (the planning horizon rule would make this an epic line): the store file's `[Ruya Store]` group and the reserved `play.` prefix are built now by T-440 and T-441, and this file is where their other half is recorded. Re-read it against `05` §18 and T-229's result before dispatch.

## Read first
- `docs/specs/10-stores.md` §1, §3, §4, §11; `docs/specs/05-play-packages.md` §18 first, then §7.3, §9.2, §11
- T-440, T-441 Outcomes (store records, the `Fetcher`, caps); T-231 (the Ed25519 encoding), T-234 (`Play1`), T-238 (the importer in the image), T-388 (the job record's kinds)

## Scope
1. **Index:** `ruya-store` fetches `PlayIndex` and its `.sig` with the store's refresh, verifies it with `PlayKey` (the verifier of the `.play` format crate, not a second implementation), applies the caps (8 MB, 5 000 packages, text and picture rules of §3.6), `expires`, and merges the entries into the catalogue with `kind: play`. Schema in `api/play/play-index.schema.json`.
2. **App page data** from the index: permissions in the closed vocabulary (an unknown key drops the entry), size, signer key id, age rating marked as the developer's claim.
3. **Install:** a job in the one queue: download (HTTPS, public addresses, redirects re-checked, size and SHA-256 enforced while streaming, resumable, free space checked first against the peak T-229 measured), then `Play1` import with the confirmed entry; the importer refuses when `id`, `build`, `play_json_sha256`, `signer_key_id` or the permissions differ from the entry. The admin gate of §4 is checked by the service.
4. **Update:** a higher `build` in the origin store's index, same developer key; never a downgrade; the manifest's own feed is ignored for store installs. The permission-diff gate of `03` §4.4 applies.
5. **`ruya-pack index <dir>`**: writes and signs the index from a folder of packages (deterministic output).
6. Mock and client: `kind`, the listing-mismatch error, the "Needs a newer RuyaOS" state.

## Out of scope
- The official store's `store.sig` pipeline (T-444). Delta downloads. "Get updates from <store>" for a sideloaded package (`10-stores.md` §10).

## Acceptance criteria
- [ ] Rust tests, one per rule of `10-stores.md` §11 (1 to 5) and per edge case of rule 9, with hostile index fixtures (oversized, wrong signature, expired, duplicate ids, a lower build, an unknown permission key, a private-address `url`); each has a revert check.
- [ ] The listing-mismatch refusal: a package whose manifest asks for `network: true` under an index entry that said `false` is refused before unpacking (test named).
- [ ] Public format: the index schema, a paragraph and example in `docs/developers/your-own-store.md`, `samples/store/` gains a `.play` shelf built with `ruya-pack index`, mock support, the conformance check below.
- [ ] VM (this task, if the unit or policy of either service changes; else lead run): `scripts/vm-store-check.sh play`: a store with one Flatpak and one `.play` is added; both appear; the `.play` installs, launches through `Session1`, updates to a higher build, refuses a re-signed copy with another key, and stays installed after the store is removed.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 rust
.\scripts\dev.ps1 test
```

## Docs to update
- `10-stores.md` §11 (built marks), `05-play-packages.md` §11 and §13, `docs/developers/your-own-store.md`, `api-surface.md`.

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: vm-store-check.sh play)`._
