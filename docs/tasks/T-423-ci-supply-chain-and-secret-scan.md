# T-423 - CI gates: dependency advisories and licences, secret scan, bus-policy lint

Status: done · Phase: 2 · Depends: — · Area: ci, scripts, services · Size: S · Owner: builder · Complexity: normal · Developer surface: none

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
Verified: host (GitHub run itself unverified; dev.ps1 test ALL GREEN: 1029 QML passed, 84 skips, Rust ok)

Built: `services/deny.toml`; `.github/workflows/supply-chain.yml` (cargo-deny 0.20.2 release binary, push/PR/weekly cron); CI `lint` job now has `fetch-depth: 0`, `scan-secrets.ps1` and `lint-bus-policies.ps1 -SelfTest`; `.githooks/pre-commit` scans staged additions; `scripts/lint-bus-policies.ps1` (+ `-SelfTest` fixtures) wired into `dev.ps1 test` as "bus policy lint"; `docs/dev-setup.md`.

Proofs:
- `cargo deny --locked check advisories licenses sources bans` passes on the tree. Licence gate: a scratch crate with `license = "GPL-3.0-only"` and the same `deny.toml` fails (`failed to satisfy license requirements`, rc 4); scratch deleted. The yanked rule (`yanked = "deny"`) is configured but no yanked crate exists to exercise it: unproven.
- Secret scan: in a scratch clone with a committed file holding a fake PEM private-key header line, `powershell scripts/scan-secrets.ps1` (Windows PowerShell 5.1) exits 1. The CI command on Linux is covered in round 2 below. The pre-commit hook refused the same file at `git commit` (it is active in this clone via `core.hooksPath`, which I did not set).
- Bus lint: green on the six policies; `-SelfTest` has 7 cases (control + missing default deny, allow in default, allow for another user, group policy, ruya-link without `send_member`, ruya-link owning). Revert checks: deleting the `deny` from `org.ruyaos.Store1.conf` made the lint red (file restored); removing `send_member` from the good fixture made the self-test red ("refused the good fixture"); restored.

Advisories ignored (dated 2026-11-10, see `deny.toml`): RUSTSEC-2026-0194/0195 quick-xml 0.37 (needs 0.41, ruya-store), RUSTSEC-2026-0370/0371/0372 zvariant, zbus_names, zvariant_derive unmaintained (merged into zbus 6).

Deviations: (1) The lint requires the default-context `deny send_destination` per allowed name, not explicit default denies of `own` and receive: the existing six files have none, the bus denies them implicitly, and adding them would be an image change needing a VM run. (2) The `ruya-library` policy `allow own` is permitted for that user only (task text lists root/ruya-shell/ruya-link). (3) No `ruya-link` policy exists yet; its rule is exercised by fixtures only. (4) The hook's secret check is plain `grep` placed before the PowerShell lookup, so it also runs where only the text lint is skipped.

Round 2 (reviewer findings):
- `scan-secrets.ps1` threw on Linux pwsh because `$env:ProgramFiles` is unset; the Git-for-Windows PATH tweak is now guarded by `if ($env:ProgramFiles)`. Proof on Linux: PowerShell (the `mcr.microsoft.com/powershell:ubuntu-24.04` container under podman in WSL, with git installed), `ProgramFiles` empty, a clean clone of the branch: `pwsh -NoProfile -File scripts/scan-secrets.ps1` exit 0, `lint-bus-policies.ps1 -SelfTest` exit 0; after committing a fake private-key header file, the scan exits 1 (FAIL: private key). The container image and clone were removed.
- `lint-bus-policies.ps1`: for `ruya-link`, `send_destination` and `send_member` must be non-empty and contain no `*`; three new fixtures (wildcard member, wildcard destination, empty member), 10 cases in total.
- Not done (optional): checksum verification of the cargo-deny tarball.
