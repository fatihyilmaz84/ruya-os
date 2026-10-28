# RuyaOS — instructions for AI contributors

RuyaOS is an open-source, immutable (Fedora bootc) console OS for living-room PCs. It boots straight into a controller-first Qt Quick shell. You are continuing an existing codebase with recorded decisions. **Follow this file exactly.** Area rules live in `shell/CLAUDE.md`, `services/CLAUDE.md` and `image/CLAUDE.md` and load when you work there.

## Where the truth lives

| What | File |
|---|---|
| Board (open tasks, NEXT), Inbox, blockers, owner decisions, last five sessions. **Read first, update last.** | `docs/STATUS.md` |
| Work items with acceptance criteria; a finished task is recorded in its own file | `docs/tasks/T-*.md` (format: `docs/tasks/README.md`) |
| Roles (owner, Opus lead, Sonnet builder), the lead procedure, lead handoff | `docs/LEAD.md`, `docs/LEAD-NOTES.md` |
| Product, architecture, decisions (ADRs) | `docs/specs/00-overview.md`; platform/image `01`, shell UX `02`, services/apps `03` |
| Shell ↔ service contracts | `api/dbus/*.xml` |
| How to build/run on this machine | `docs/dev-setup.md`, `scripts/dev.ps1` |
| Shell how-tos (pages, settings rows, modals, text input, translations) | `shell/PATTERNS.md` |
| Archives, **never needed to start a task** | `docs/STATUS-done.md` (work before T-132), `docs/STATUS-log.md` (old sessions) |

## Session workflow (do every step, in order)

0. **Which session?** Asked for a **lead session**: follow `docs/LEAD.md`. A **planning session**: `docs/tasks/PLANNING.md`. Anything else is a **builder session**: the steps below. Builders don't create tasks; they add Inbox lines.
1. **Orient.** Read `docs/STATUS.md`. Take **NEXT**, or else the first `todo` whose dependencies are all `done`. Skip **[lead]** tasks. **One task per session**, unless its file says it is small enough to pair. If asked for another task in the same session, do it but say once that a fresh session is cheaper (every turn re-reads the whole conversation).
   - `git status` shows changes you didn't make? Another session may be running: stop and tell the user.
   - Nothing qualifies? Stop and say the backlog needs a planning session. Don't invent work.
   - Inbox has 5+ items? Do your task, then recommend a planning session. Lead review due (see the board)? Recommend a lead session.
2. **Read before coding.** The whole task file, every spec section it links, the `CLAUDE.md` of each area you touch, and the existing code you will change. Read the Outcome of a dependency only when the task's Hints point to it.
3. **Claim it.** Set `Status: in-progress` in the task file header **and** on the `docs/STATUS.md` board (`scripts/lint-board.ps1` fails if they differ).
4. **Build within scope.** Implement exactly the task's Scope.
   - **Every follow-up** you notice (debt, flaky build, missing feature, spec gap) is one line in the **Inbox**. A follow-up that exists only in prose is lost.
   - Write a task file yourself only if your task can't finish without it.
   - Crossing the shell/service boundary: **write or extend the D-Bus XML first**; the mock, the D-Bus client and the Rust service all follow it.
   - **Contracts are drafts until the first release.** If the task can't be done cleanly within the contract, extend it: in the same commit update the XML, the Rust service and its tests, the mock and the D-Bus client, and explain it in the Outcome. No workarounds such as extra calls to recover missing data. This applies even if a task says "don't change the contract" (that means "no unnecessary changes"). Never break behaviour other code relies on.
5. **Verify.**
   - `.\scripts\dev.ps1 test` must end with `ALL GREEN`. Its Qt Quick tests run **offscreen**, independent of the desktop. A red `test` is a real failure.
   - UI change: also `.\scripts\dev.ps1 shots` (real GPU windows). Read the screenshots your task changed from `output\shell-shots\review\` (half size) and check them against the criteria; open a full-size PNG only for small text. Fix what you see.
   - `shots` depends on the desktop: if it fails while `test` is green, suspect a locked screen or a window that stole focus, and re-run before changing anything (`TEST WINDOW LOST ACTIVATION` followed by an `activeFocus` failure is the desktop, not the product). Never edit a test to suit the desktop.
6. **Document.**
   - Task file: fill **Outcome**, starting with a `Verified:` line (host / vm / unverified / hw, see the legend in STATUS), then what was built, files, deviations. Set `Status: done` (or `blocked`, with the reason).
   - Update every spec section whose behaviour changed (specs describe what the code does) and `docs/dev-setup.md` if commands changed.
   - `docs/STATUS.md`: **delete the task's board row** (done work leaves the board; there is no Done table), move **NEXT**, add a session-log entry of at most 4 lines at the top.
7. **Commit.** One commit per task (a small series is fine), format below. **Builders never push.** The lead pushes `main` to `origin` (https://github.com/fatihyilmaz84/ruya-os.git) at the end of every lead session, only after `scripts\scan-secrets.ps1` passes (owner, 2026-10-28). `image/bib/config.toml` holds the dev SSH key and stays git-ignored.

## Definition of done (all must hold)

- [ ] Every acceptance criterion is met **and** checked by a test or a reviewed screenshot.
- [ ] `.\scripts\dev.ps1 test` → `ALL GREEN`. No test was weakened, skipped or deleted to get there.
- [ ] New QML/C++ files are in `shell/CMakeLists.txt`; new strings use `qsTr()`.
- [ ] Contracts, mocks, D-Bus clients and services agree (method names, argument order, status strings).
- [ ] Task Outcome, specs and STATUS are updated. Whatever couldn't run on this machine is marked **unverified**.

## Hard rules

- **Decisions.** ADRs marked *Accepted* in `00-overview.md` are binding. If a task seems to need a different decision, or a new owner-level one (legal, licensing, product scope, spending, publishing), don't decide: add a *Proposed* ADR, mark the task `blocked` with the question, and stop.
- **Host.** Windows, with a Fedora 44 WSL distribution for image builds and QEMU (WHPX) for boot tests (`docs/dev-setup.md`). Never install system software or change system settings; `dnf` inside the WSL distribution is fine.
  - **Image changes** (Containerfile, `image/`, units, services as packaged) are built and boot-tested: `scripts/build.sh` + `make-disk.sh` in WSL, then `scripts\smoke-test.ps1`. Such a task is not `done` until it boots with `RUYA_BOOT_OK`. Builds take 3–30 minutes: run them in the background.
  - **Unverifiable here** (say so, never claim it works): real GPU/KPI numbers, controllers in the VM, audio output in the VM (no sound device unless `-Audio`), and the shell talking to services over D-Bus unless you test inside the VM over SSH.
- **Tests are the spec's teeth.** Never weaken an assertion, add `skip()`, or delete a test to get green. If a test is wrong, fix it and say why in the Outcome.
- **Security invariants:**
  - PIN hashes never leave `ruya-profiles`.
  - No private keys or secrets in the repo or the image.
  - Nothing auto-runs from removable media.
  - Third-party apps run only in Flatpak sandboxes, never as root or as `ruya-shell`.
  - Services keep their systemd hardening.
  - D-Bus policies stay restrictive: the shell and root only.
- **Honesty in the log.** STATUS and Outcomes report what actually happened, including failures and anything left undone.

## Working style

- **Read lean.** Everything you read is paid for again on every later turn. Read line ranges (`Read` with offset/limit, `grep -n`), don't re-read what is in context, don't dump directories, filter long output (`dev.ps1 ... | Select-String`), read only the screenshots your task changed. Don't open the archives.
- **Small steps.** Build and run the relevant check (`dev.ps1 shell` or `rust`) after each meaningful change.
- **Copy existing patterns.** `ruya-profiles` (Rust), `shell/src/profiles` and `PinPad.qml` (shell) are the reference implementations; `shell/src/network` is the newest complete backend with a pane.
- **Ambiguity.** If a criterion reads two ways, take the reading closest to the spec and say so in the Outcome. Don't ask for routine technical choices.
- **Stuck** (the same failure after about 3 genuinely different attempts): get back to a green tree (`git stash` or revert), describe what you tried in the Outcome, set `blocked`, and commit only the docs. Never commit a red tree.
- **Stay in scope.** No unrelated refactors, dependency upgrades or reformatting.

## Commit messages

```
<area>: <imperative summary under 72 chars>      e.g. "shell: add page navigation framework (T-101)"

What changed and why, wrapped at 72 columns. Mention the task id.
Verification: dev.ps1 test ALL GREEN; screenshots reviewed (if UI).
Unverified: <anything Linux-only>, or "none".
```
Areas: `shell`, `services`, `image`, `api`, `docs`, `scripts`, `ci`. Add the attribution trailer your harness specifies.

## Environment pitfalls (learned the hard way)

- **Shells.** The PowerShell tool is **5.1** (no `&&`, no ternary); Git Bash is also available. `scripts\dev.ps1` already works around the quirks: use it.
- **Files get corrupted by host tools** (it reached `main` twice). Backslashes in text sent through Bash heredocs, `sed` or Python string literals become control characters: **write text containing backslashes (Windows paths, line continuations, regex) with the Write/Edit tools.** Python here reads and writes **cp1252**: pass `encoding="utf-8"` to every `open`, or use Edit. `scripts/lint-text.ps1` (in `dev.ps1 test` and CI) fails on invalid UTF-8, control characters and tabs in tracked text files (new files count once `git add`ed).
- **Qt** 6.10.3 (MSVC) at `D:\dev\Qt\6.10.3\msvc2022_64`; the image uses Fedora's Qt (≥ 6.8), so use no newer APIs. MSVC compiles C++17 (no `[=, this]`).
- **Rendering.** Offscreen (tests, CI) is the software renderer, where `MultiEffect` draws nothing: assert properties (`visible`, `blurMax`, focus), never pixels. Only `shots` renders on the GPU.
- **qmllint** needs the module response file and `--max-warnings 0`; `dev.ps1` does that.
- **Line endings.** Files that reach the Linux image stay LF (`.gitattributes`). Shell scripts need the exec bit: `git update-index --chmod=+x <file>`.
- **"X is not defined" for a new C++ QML type** should not happen (a build step regenerates the type registration, T-116); if it does, run `scripts\repro-first-build.ps1`, and as a last resort delete `shell\build-win`. Never "fix" it by changing tests.
- **Mock services.** Off Linux the shell uses mocks. Mock profiles: Player One (admin, PIN 1234), Ada (no PIN), Guest.
