# RuyaOS — instructions for AI contributors

RuyaOS is an open-source, immutable (Fedora bootc) console OS for living-room PCs. It boots straight into a controller-first Qt Quick shell. You are continuing an existing codebase with recorded decisions. **Follow this file exactly.** Area-specific rules live in `shell/CLAUDE.md`, `services/CLAUDE.md` and `image/CLAUDE.md`, and are loaded when you work there.

## Where the truth lives

| What | File |
|---|---|
| Progress board, blockers, session log | `docs/STATUS.md`. **Read first, update last.** |
| Work items with acceptance criteria | `docs/tasks/T-*.md` (format: `docs/tasks/README.md`) |
| Product, architecture, decisions (ADRs) | `docs/specs/00-overview.md` |
| Platform/image, shell UX, services/apps | `docs/specs/01-platform.md`, `02-shell.md`, `03-services-and-apps.md` |
| Shell ↔ service contracts | `api/dbus/*.xml` |
| How to build/run on this machine | `docs/dev-setup.md`, `scripts/dev.ps1` |

## Session workflow (do every step, in order)

1. **Orient.** Read `docs/STATUS.md`. Take the task marked **NEXT**, or else the first `todo` whose dependencies are all `done`. **One task per session**, unless the task file says it is small enough to pair.
2. **Read before coding.** Read the whole task file, every spec section it links, and the `CLAUDE.md` of each area you will touch. Read the existing code you will change.
3. **Claim it.** In `docs/STATUS.md`, set the task to `in-progress`.
4. **Build within scope.** Implement exactly the task's requirements. Anything outside "Scope" becomes a note in the task's Outcome section or a new task (see `docs/tasks/README.md`), never a silent extra.
   - If the work crosses the shell/service boundary, **write or extend the D-Bus XML contract first**. The mock backend, the D-Bus backend and the Rust service all follow it.
5. **Verify.** Run `.\scripts\dev.ps1 test`; it must end with `ALL GREEN`. For any UI change, also run `.\scripts\dev.ps1 shots`, open the PNGs in `output\shell-shots\` with the Read tool, and check them against the task's acceptance criteria (layout, overlap, focus ring visible, text readable). Fix what you see.
6. **Document.**
   - Fill in the task file's **Outcome** section: what was built, the files involved, how it was verified, and deviations.
   - Update every spec section whose described behaviour changed. Specs must describe what the code does.
   - Update `docs/dev-setup.md` if the workflow or commands changed.
   - In `docs/STATUS.md`: set the task to `done` (or `blocked`, with the reason), move **NEXT** to the next task, and add a session-log entry at the top.
7. **Commit.** One commit per task (a small series is fine). Use the format below. **Never push**; there is no remote, and publishing is the owner's decision.

## Definition of done (all must hold)

- [ ] Every acceptance criterion in the task file is met **and** checked by a test or by a reviewed screenshot.
- [ ] `.\scripts\dev.ps1 test` → `ALL GREEN`. No test was weakened, skipped or deleted to get there.
- [ ] New QML files are listed in `shell/CMakeLists.txt`; new user-visible strings use `qsTr()`.
- [ ] Contracts, mocks, D-Bus clients and services agree (same method names, argument order, status strings).
- [ ] Specs, the task Outcome, and STATUS are updated. Anything that couldn't run on this machine is marked **unverified**.

## Hard rules

- **Decisions.** ADRs marked *Accepted* in `00-overview.md` are binding. If a task seems to need a different decision, or a new owner-level one (legal, licensing, product scope, spending, publishing), do not decide it yourself. Add a *Proposed* ADR, mark the task `blocked` with the question, and stop.
- **This machine is Windows with no Linux VM.** Never install system software, enable WSL/Hyper-V, or change system settings. Linux-only code (image, systemd units, `#[cfg(target_os = "linux")]` paths, QtDBus against a live bus) can only be type-checked and syntax-checked here. Say so; never claim it works.
- **Tests are the spec's teeth.** Never weaken an assertion, add `skip()`, or delete a test to get green. If a test is wrong, fix it and explain why in the Outcome.
- **Security invariants**:
  - PIN hashes never leave `ruya-profiles`.
  - No private keys or secrets in the repo or the image.
  - Nothing auto-runs from removable media.
  - Third-party apps run only in Flatpak sandboxes, never as root or as `ruya-shell`.
  - Services keep their systemd hardening.
  - D-Bus policies stay restrictive: the shell and root only.
- **Honesty in the log.** STATUS and Outcome sections report what actually happened, including failures and anything left undone.

## Working style

- **Small steps.** Build and run the relevant checks (`dev.ps1 shell` or `dev.ps1 rust`) after each meaningful change, not only at the end.
- **Copy existing patterns.** `ruya-profiles` (Rust) and `shell/src/profiles` + `PinPad.qml` (shell) are the reference implementations. Read them before writing a new service, backend or modal.
- **Ambiguity.** When an acceptance criterion can be read two ways, choose the reading closest to the spec and write the choice in the Outcome. Don't ask for routine technical choices.
- **Stuck** (the same failure after about 3 genuinely different attempts): get back to a green tree (`git stash`, or revert your change), describe the problem and what you tried in the task's Outcome, set it to `blocked` in STATUS, and commit only the docs. Never commit a red tree.
- **Stay in scope.** No refactors of unrelated code, no dependency upgrades, no reformatting of files you didn't otherwise change.

## Commit messages

```
<area>: <imperative summary under 72 chars>      e.g. "shell: add page navigation framework (T-101)"

What changed and why, wrapped at 72 columns. Mention the task id.
Verification: dev.ps1 test ALL GREEN; screenshots reviewed (if UI).
Unverified: <anything Linux-only>, or "none".
```
Areas: `shell`, `services`, `image`, `api`, `docs`, `scripts`, `ci`. Add the attribution trailer your harness specifies.

## Environment facts and pitfalls (learned the hard way)

- **Shells.** Windows 11. The PowerShell tool is **5.1**, which has no `&&` and no ternary. Git Bash is also available. `scripts\dev.ps1` already works around PowerShell's quirks, so use it instead of ad-hoc commands.
- **Backslashes get mangled** when text goes through Bash heredocs, `sed` or Python string literals: `\b`, `\n` and `\r` turn into control characters. **Write any text containing backslashes (Windows paths, line continuations, regex) with the Write/Edit tools.** Before committing, make sure no file gained stray control characters.
- **Qt** 6.10.3 for MSVC lives at `D:\dev\Qt\6.10.3\msvc2022_64`. The production image uses Fedora's Qt (≥ 6.8), so don't use APIs newer than 6.8.
- **MSVC compiles C++17.** C++20-only syntax such as `[=, this]` captures fails.
- **Rendering.** `QT_QPA_PLATFORM=offscreen` switches to the software renderer, where `MultiEffect` draws nothing. Visual checks need real windows, and `dev.ps1 shots` uses real windows.
- **qmllint** only means anything with the module response file and `--max-warnings 0`. `dev.ps1` already does that.
- **Line endings.** Files that end up in the Linux image must stay LF (enforced by `.gitattributes`). Shell scripts need the exec bit in git: `git update-index --chmod=+x <file>`.
- **Mock services.** Off Linux, the shell uses mock services. The mock profiles are Player One (admin, PIN 1234), Ada (no PIN) and Guest.
