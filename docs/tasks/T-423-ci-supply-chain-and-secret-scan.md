# T-423 - CI gates: dependency advisories and licences, secret scan, bus-policy lint

Status: todo · Phase: 2 · Depends: — · Area: ci, scripts, services · Size: S · Owner: builder · Complexity: normal · Developer surface: none

## Goal
A vulnerable or wrongly licensed crate, a committed secret, or a D-Bus policy that is no longer deny-by-default fails on every push, not only when the lead remembers to run a script. Today `scan-secrets.ps1` runs only inside `push-main.ps1`, CI has no advisory or licence check, and nothing reads the bus policies (plan audit 2026-11-10).

## Read first
- `.github/workflows/ci.yml`, `scripts/scan-secrets.ps1`, `scripts/push-main.ps1`, `.githooks/pre-commit`
- `image/` bus policy files (`system.d/*.conf`; find them with Glob) and root `CLAUDE.md`, Security invariants
- `docs/specs/00-overview.md` ADR-008 (licence), ADR-029 (the `ruya-link` allow-list is the one exception)

## Scope
1. `services/deny.toml` and a CI step `cargo deny check advisories licenses sources bans` (pinned `cargo-deny` version, `--locked`). Licences allowed: those compatible with ADR-008; every exception is a named entry with a reason. Sources: crates.io only.
2. CI runs `scripts/scan-secrets.ps1` in the lint job (full tree, not only the pushed range).
3. `.githooks/pre-commit` also runs the secret scan on staged files (the hook already runs the text lint).
4. `scripts/lint-bus-policies.ps1` (in `dev.ps1 test`, `dev.ps1 docs` is not needed, and CI): every policy file has a default `deny` for own, send and receive; `allow` appears only for `root` and `ruya-shell`, plus `ruya-link` with an explicit `send_member` per line (never a whole interface or destination); no `<policy context="default">` allow of `send_destination`. Fixture tests for each refusal.
5. A weekly scheduled CI run of step 1 (`schedule:`), so a new advisory is seen without a push.

## Out of scope
- Pinning base images, signing, SBOM (T-425, T-426).
- Fixing advisories that need a major upgrade: list them as Inbox lines with a dated `ignore` entry and its reason.
- `cargo audit` as a second tool.

## Acceptance criteria
- [ ] `cargo deny check` passes on `main`; a fixture or a documented manual proof shows a GPL-3.0-only or yanked dependency failing it (Outcome says how it was proven and reverted).
- [ ] The CI lint job fails on a planted test secret in a scratch branch or a local `act`-free equivalent: running the exact CI command on a tree with a planted key file exits non-zero (test in the Outcome; the key is a fake pattern, never a real one).
- [ ] `lint-bus-policies.ps1` is green on the tree and each of its rules has a fixture it refuses (test: the lint's fixture run, named in the Outcome). Revert check: deleting the default-deny from one fixture turns the run red.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/dev-setup.md`, "Local checks and CI"; root `CLAUDE.md` only if a rule can be deleted because the lint now enforces it.

## Hints
- CI runs on GitHub with no secrets and read-only permissions: keep it that way.
- The owner must run `git config core.hooksPath .githooks` once per clone (STATUS Inbox); the hook is not active otherwise. Do not try to set it.
- `Unverified:` the GitHub run itself, unless the lead can see it.

## Outcome
_Filled in by the implementer. First line: `Verified: host`._
