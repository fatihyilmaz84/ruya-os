# T-231 — Signing, trust tiers, key continuity and revocation (pure core)

Status: todo · Phase: 7 · Depends: T-230 · Area: services, api · Size: M · Owner: lead

## Goal
The pure rules that decide how far a package is trusted: verify a signature, assign a tier, remember which key owns an id, accept a key rotation, and apply a revocation list. No D-Bus, no files outside a small state abstraction.

## Read first
- `docs/specs/05-play-packages.md` §9.2, §11 (same-key rule, feed signature), §16 Q6
- T-230's `play.files` reader; `docs/specs/01-platform.md` (how the image pins the OS signing key; the store key will be pinned the same way)

## Scope
1. **Decide and document the signature encoding** (Ed25519; reuse an existing format such as `ssh-keygen -Y sign` namespaces or minisign if a pure-Rust verifier is available under a compatible licence, else a small own format). Record the choice, the library, its licence and why in the Outcome and spec 05 §9.2. `cargo deny` must pass.
2. `play.sig` statement and verifier: binds `id`, `build`, the SHA-256 of `play.json` and of `play.files`; checks them against the package; a bad signature is an error, not `unverified`.
3. `store.sig` countersignature against a pinned store public key (a test key in tests; the real key arrives with the image build, never as a private key in the repo).
4. **Trust store** trait (id -> key id, first-seen time, allowed-key list, developer-mode flag) with an in-memory fake and a file-backed implementation (atomic writes, untrusted-input parsing like `jobs` in `ruya-store`). Rules: first sight records the key; later installs and updates of the id must match, or carry a **rotation statement** signed by the old key; otherwise `different-developer`.
5. Tier function: `official`, `developer`, `unverified`, with the reasons; permission ceilings by tier (the table in 05 §8) as data.
6. **Revocation:** `revoked.json` format (key ids, id + build ranges, content hashes, runner hashes), its own signature by the store key, `expires`; a function `is_revoked(package, runner hashes)`; the stale-cache policy for Q6 decided and written down (recommendation: warn and allow after 30 days, never block on staleness alone).
7. A key generator and signer in the library for `ruya-pack` (T-233) and tests.

## Out of scope
- Where the store key comes from in the image, the device-local OSTree key (T-238), the D-Bus surface (T-234), network fetching of revocation lists (T-241 and the Store).

## Acceptance criteria
- [ ] Tests: valid signature gives `developer`; with a valid `store.sig` gives `official`; each of these is rejected with its own error: tampered `play.json`, tampered `play.files`, a file changed (hash mismatch from T-230's reader), signature for another id, for another build, wrong key for a known id, an expired revocation list, a revocation list signed by a non-store key (`tests/signing.rs`).
- [ ] No signature gives `unverified` only when developer mode is on; otherwise `needs-developer-mode` (`tests/tiers.rs`).
- [ ] Key rotation: old-key-signed rotation accepted once, a rotation signed by the new key rejected, a replayed older rotation rejected (`tests/continuity.rs`).
- [ ] Permission ceilings: a `unverified` package asking for a high-risk permission is `uninstallable` (not reduced) (`tests/tiers.rs::ceiling_unverified_high_is_refused`).
- [ ] Reverting any check turns a named test red (map in the Outcome).
- [ ] `dev.ps1 test` ALL GREEN; `cargo deny` clean.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- Spec 05 §9.2 and §11 as built; ADR-014 if the encoding choice affects it.

## Hints
- Copy the style of `ruya-profiles` for the state file and error enums.
- Time comes from an injected clock, never `now()` inside the rules.

## Outcome
_Filled in by the implementer._
