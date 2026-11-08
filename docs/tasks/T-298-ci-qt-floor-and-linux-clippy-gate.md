# T-298 — CI: decide the Qt floor (6.8 branch) and add a Linux-native clippy gate at the pinned Rust 1.92

Status: todo · Phase: 2 · Depends: — · Area: ci, scripts (dev.ps1, push-main.ps1), docs (CLAUDE.md, dev-setup), shell/CMakeLists.txt · Size: S · Owner: lead

## Goal
Two classes of CI-only surprises disappear: clippy 1.92 on Linux flags something no local run does (the `statvfs` `as u64` casts of 2026-11-07), and the Qt 6.8 floor promised in `CLAUDE.md` is not built or tested anywhere.

## Read first
- `.github/workflows/ci.yml` (Rust job: `rustup toolchain install 1.92.0`, `cargo clippy --all-targets --locked -- -D warnings`), `scripts/dev.ps1` (`rust`: clippy for Windows and for `x86_64-unknown-linux-gnu`), `scripts/push-main.ps1`, `docs/dev-setup.md`
- `shell/CMakeLists.txt` lines 9-19, 249-250 (the conditional `GuiPrivate`: a `find_package` component only from Qt 6.9), root `CLAUDE.md` (Qt 6.8 floor), `01-platform.md` (Qt)
- `services/ruya-devices/src/sysusage.rs`, `udisks.rs` (the cast allow); STATUS-parked.md "Inbox triage 2026-11-07", bullets T-298

## Scope
Owner **lead** because it touches the WSL toolchain and the project's stated Qt floor (not owner-level: no legal, spend or scope question).
1. **Rust gate:** `dev.ps1 rust-linux` runs, in the Fedora WSL distribution, `cargo +1.92.0 clippy --all-targets --locked -- -D warnings` for the services workspace, with a user-space rustup in the WSL home (no dnf Rust change, no system install); `dev.ps1 test` stays Windows-only and fast. If the lead prefers not to download a toolchain: a CI pre-check job is the fallback and `push-main.ps1` waits for it.
2. `push-main.ps1` runs `rust-linux` (or says it was skipped) before the push and prints `gh run list` afterwards; `docs/dev-setup.md` documents both.
3. **Qt floor:** decide between (a) raising the floor to Qt 6.9 (Fedora 44 ships 6.10 or newer, the dev host has 6.10.3, no builder has 6.8) and deleting the conditional `GuiPrivate` branch, or (b) a CI job building and testing against Qt 6.8 (aqtinstall). Recommendation: (a). Apply it consistently: `CMakeLists.txt` (`find_package`, `qt_standard_project_setup(REQUIRES ...)`), root `CLAUDE.md`, `01-platform.md`, the pitfalls line "use no newer APIs".

## Out of scope
- Other lints, caching speed-ups, an arm64 build.

## Acceptance criteria
- [ ] `dev.ps1 rust-linux` exits 0 on the tree and exits 1 when `let n = st.f_blocks as u64;` (a statvfs cast clippy 1.92 flags) is seeded in a scratch copy (shown in the Outcome).
- [ ] `ci.yml` and `dev.ps1` use the same pinned toolchain string (one grep in the Outcome).
- [ ] The Qt decision is written in `CLAUDE.md`/`01` and `shell/CMakeLists.txt` configures and builds on the host (`dev.ps1 build`); for (a) the conditional branch is gone and `Qt6::GuiPrivate` links on the dev host and in CI (CI run green after the push).
- [ ] `.\scripts\dev.ps1 test` ALL GREEN.

## Verification
```powershell
.\scripts\dev.ps1 rust-linux
.\scripts\dev.ps1 test
gh run list --limit 3
```

## Docs to update
- `docs/dev-setup.md`, root `CLAUDE.md` (host and Qt lines), `01-platform.md`.

## Hints
- Do not run beside an image build (WSL busy). Overlaps nothing in `shell/` except the CMake lines above.

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
