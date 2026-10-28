# T-141 — `vm-goto.ps1`: take a VM past the first-boot wizard to a named page

Status: todo · Phase: 2 · Depends: — · Area: scripts, docs · Size: S

## Goal
A VM task can take a screenshot of any Settings pane with one command, instead of driving the first-boot wizard and the menus by hand. T-132 had to replace its Settings → Network screenshot with a probe because of this.

## Read first
- `docs/dev-setup.md`: "Build → disk → boot" (`-Work`), the VM tools table (`vm-keys.ps1`, `vm-screenshot.ps1`, `vm-lib.ps1`) and the wizard walk-through with its pitfalls (software rendering lags the keys)
- `scripts/vm-keys.ps1`, `scripts/vm-screenshot.ps1`, `scripts/vm-lib.ps1`
- `shell/qml/Shell.qml` and the Settings page (the order of the Settings panes), `shell/qml/SetupWizard.qml` (or wherever T-106's wizard lives: its steps)

## Scope
1. `scripts/vm-goto.ps1 <target>` for a running VM (monitor on `127.0.0.1:4444`): if the shell shows the wizard, finish it with fixed answers (English, profile "Player One", no PIN or PIN `1234`: pick one and document it), then reach `<target>`: at least `home`, `settings-network`, `settings-audio`, `settings-profiles`, `store`. Then `vm-screenshot.ps1 <target>`.
2. **Robust against lag:** don't rely on fixed sleeps alone. After each step wait for evidence: read the shell's state over SSH (e.g. its journal lines, or `busctl` on `Profiles1.ActiveProfile` after the wizard), or compare screenshots until the screen stops changing, with a timeout and a clear error naming the step that failed.
3. Use `-Work` disks: running it twice on the same disk skips the finished wizard.
4. `docs/dev-setup.md`: the command, the targets, the fixed wizard answers.

## Out of scope
- Changing the shell to make this easier (no test hooks or debug keys in the product), controller input, the compositor session (T-130).

## Acceptance criteria
- [ ] On a fresh `-Work` disk from the current image: `vm-goto.ps1 settings-network` ends with `output\vm-shots\settings-network.png` showing Settings → Network with the wired connection connected (image in the Outcome, reviewed).
- [ ] A second run on the same disk (wizard already done) reaches `settings-audio` and `store` (images reviewed).
- [ ] A wrong target or a VM that is not running fails within 10 s with a message, not a hang.
- [ ] `dev.ps1 test` ALL GREEN (the text lint covers the new script).

## Verification
```powershell
.\scripts\smoke-test.ps1 -Work -Keep
.\scripts\vm-goto.ps1 settings-network
```

## Docs to update
- `docs/dev-setup.md` (VM tools table and a short section).

## Hints
- Mock profiles do not exist in the VM: the wizard creates the first profile there.
- `vm-keys.ps1 -DelayMs` 1500 to 2000 is what the documented walk-through needed; screenshots of a software-rendered VM take about a second each.
- PowerShell 5.1 strips inner quotes from arguments to `ssh`: put multi-step guest commands in a script file and `scp` it (`dev-setup.md` problem log).
