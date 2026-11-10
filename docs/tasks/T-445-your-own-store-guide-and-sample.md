# T-445 - Developer guide: "Your own store", with a sample that builds one

Status: todo · Phase: 3 · Depends: T-441 · Area: docs, samples, scripts · Size: S · Owner: builder · Complexity: normal · Developer surface: public-format

## Goal
A developer can read one chapter, run one script and have a store a RuyaOS console accepts: a signed Flatpak repository with the sample game, a store file, the well-known address (`/.well-known/ruyaos-store`). The chapter also says what the console will refuse, so nobody learns it from a failed add. ADR-032 point 7, `docs/specs/10-stores.md` §9.

## Read first
- `docs/specs/10-stores.md` (all), `docs/developers/api-surface.md` (tier C and the extra Definition of done), `docs/developers/publishing.md`, `README.md` of that folder (chapter list, Sources footer rule)
- `samples/hello-game/`, `scripts/lint-dev-docs.ps1` (what it checks in a chapter), `scripts/vm-sample-check.sh`
- T-440 and T-441 Outcomes (the exact refusals and limits as built)

## Scope
1. `docs/developers/your-own-store.md`: what a store is; make one (export, sign, the `.flatpakrepo` fields the console reads, hosting as static files over HTTPS, the well-known path); how a player adds it; the rules of `10-stores.md` §3 as "what the console refuses and why" (ids you cannot use, no runtimes, the caps, pictures over HTTPS only, the frozen title); key care (keep it offline, what happens if it changes: players must add the store again); updating apps; what is not supported (sign-in, paid apps, `.flatpakref`). Linked from the README's chapter list and from `publishing.md` (its "Your own repository" row).
2. `samples/store/make-store.sh`: builds the sample game, exports it into a repository signed with a key it generates in a temporary directory, writes the `.flatpakrepo` and the well-known copy, prints the fingerprint and how to serve the folder. No key is ever written into the repository tree (`.gitignore` the output; `scan-secrets` stays green).
3. `api-surface.md`: the store format as a tier-C line (`public-format`, experimental until the first release), pointing to the chapter.
4. `lint-dev-docs.ps1` covers the new chapter (links, shell blocks parse, the script blocks quote the sample script).

## Out of scope
- The `.play` shelf of a store (T-446 adds it to this chapter and to the sample).
- `ruya store check` in the CLI (`10-stores.md` §10). Hosting advice for a named provider. Anything about the official store (T-444).

## Acceptance criteria
- [ ] `lint-dev-docs.ps1` green with the chapter listed and its Sources footer; a quoted block that differs from `make-store.sh` fails the lint (the existing self-check pattern, extended).
- [ ] Conformance: `scripts/vm-store-check.sh stores` uses `samples/store/make-store.sh` to make its good fixture store (one script, not two), so a console accepting the sample store is checked on every image (VM, lead run).
- [ ] Each "the console refuses" statement in the chapter names the status from `10-stores.md` §2 or the rule of §3, and matches T-440/T-441 as built (the reviewer checks five at random).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 docs
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/developers/README.md`, `publishing.md`, `api-surface.md`, `docs/specs/10-stores.md` §9 (built).

## Hints
- The script runs on Linux (WSL here); the lint on Windows only parses it. LF line endings and the exec bit (`git update-index --chmod=+x`).

## Outcome
_Filled in by the implementer. First line: `Verified: host (vm pending: vm-store-check.sh stores)`._
