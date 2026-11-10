# T-426 - EPIC release security (Phase 6): what must be true before an image is given to anyone, as a spec and a task list

Status: todo · Phase: 6 · Depends: T-424, T-425 · Area: docs · Size: epic (a spec and a child list; nobody implements it directly) · Owner: lead · Developer surface: none

**Owner answer (2026-11-10, asked for the default store, ADR-032):** signing keys are held by the owner, offline, and releases are signed by hand; no signing key in CI. Item 1 starts from that.

## Goal
The roadmap's Phase 6 "Release" has no security task: signing, update authenticity, data at rest and factory reset exist only as sentences in `01-platform.md` (plan audit 2026-11-10). This epic turns them into a short spec section with decisions and into child tasks, and puts the owner-level questions in STATUS. It builds nothing.

## Read first
- `docs/specs/01-platform.md` §2.3, §3 (3.1 SELinux, 3.4 encryption, 3.5 signing), §4 (updates), §5.3 (factory reset); `docs/specs/03-services-and-apps.md` §7; ADR-006, ADR-009
- T-424's first baseline and its Inbox lines; T-425's Outcome
- `docs/tasks/PLANNING.md` (a task is written only when it is within reach: write child task files for the first two items you would build, a one-line list for the rest)

## Scope
Decide, or put to the owner with options and a recommendation, and write into `01-platform.md` §3 and §4:
1. **Image signing and verification:** the registry, cosign key or keyless, where the public key and `policy.json` live in the image, what the device refuses. The private key is never in the repository, the image or CI logs: who holds it (owner-level).
2. **Update authenticity and downgrade:** the update is accepted only when signed; a rule against being fed an older signed image (version floor), and how manual rollback still works.
3. **Secure Boot:** the chain for the stock kernel; the NVIDIA module key (01 §2.3 says "ephemeral", no task); the `bootloader-update` failure of T-299 as a symptom.
4. **Data at rest:** full-disk or per-profile encryption, TPM unlock without a keyboard, what a stolen console exposes (PIN hashes, tokens of T-316 and launchers, Wi-Fi keys). Cost on the low tier.
5. **Factory reset:** what is wiped, proof that it is (the "Open:" question of 01 §5.3), and that `ruya-link` pairings and keys die with it (T-411 relies on it).
6. **PIN storage parameters:** `Argon2::default()` is unpinned today: fixed parameters, a test that asserts them, a migration rule.
7. **Store apps' permission ceilings:** today a Flathub app with `--filesystem=host` or broad bus access is installed after an admin PIN (T-152); decide whether some permissions are refused or stripped for every Store app (product scope: owner-level).
8. **Kernel and sysctl hardening**, the kernel command line, and what T-201 decides about sysrq and panic.
9. **Supply-chain record:** an SBOM per image, a vulnerability scan of the image content, where they are kept.
10. **Hostile input:** one list of every parser of outside data (sound themes, artwork, `.play`, ROM archives, mapping profiles, web uploads, AppStream) with its owning task and whether it has fuzz or property tests; a child task for the ones that have none.
11. **The release installer:** it must not erase a disk without asking (the dev ISO does, B-002).

## Out of scope
- Building any of it; publishing; choosing a hosting provider (owner).

## Acceptance criteria
- [ ] `01-platform.md` §3/§4 has one paragraph per item above marked decided (lead or owner, date), or open with the question id in STATUS "Open owner decisions".
- [ ] Every decided item names its child task id or says "epic line, written when Phase 6 is next"; the first two child task files exist and pass the quality bar; the board has their rows.
- [ ] Item 10's table lists every parser with a task id and a test name or "none: T-nnn".
- [ ] `.\scripts\dev.ps1 docs` green.

## Verification
```powershell
.\scripts\dev.ps1 docs
```

## Docs to update
- `docs/specs/01-platform.md`, `docs/specs/00-overview.md` §6 (Phase 6 exit criteria name these checks), STATUS open decisions.

## Hints
- T-423 (CI gates), T-424 (posture baseline) and T-425 (variants) are the parts that could be built now; this epic is everything that needs a decision first.

## Outcome
_Filled in by the implementer. First line: `Verified: host` (documents only)._
