# T-229 — Spike: can a `.play` run as a generated Flatpak app with Wine?

Status: todo · Phase: 7 · Depends: T-228, T-164 · Area: image, docs · Size: M · Owner: lead

## Goal
Answer, on the VM, the questions that decide the install and run model of `docs/specs/05-play-packages.md` before any `.play` code is written, and update spec 05 and the child tasks with the answers. No product code: throw-away scripts under `scripts/spikes/play/` (kept, so the result can be repeated).

## Read first
- `docs/specs/05-play-packages.md` §6.4, §7.1, §16 (Q1 to Q4), ADR-014
- `docs/specs/03-services-and-apps.md` §4.1 (how `ruya-session` runs `flatpak run`), §4.3 (`ruya-store`, never `--no-gpg-verify`), `docs/developers/permissions-and-sandbox.md`
- T-164 (per-profile sockets; a window must be able to appear), T-162 Outcome (what the session service does)

## Scope
1. **Q1, import as a Flatpak.** By hand, build a Flatpak app `play.test.hello` from a folder (`flatpak build-init/finish`, a local OSTree repo signed with a freshly generated local GPG key, installed as a system remote with signature checking on) whose `command` is a launcher from an extension (`org.ruyaos.Play.Launcher`) and whose payload is a small native program; launch it through `Session1`. Measure the time and disk for a 2 GB and a 20 GB generated payload (commit time, install time, deduplication of two apps bundling the same large file). Report what Flatpak refuses or needs (extension points, `--no-gpg-verify` must not be needed).
2. **Q2, Wine display.** Run a freeware Windows program under Wine (Flatpak extension or runtime) with (a) Xwayland and (b) Wine's Wayland driver, against the shell's compositor (T-164 sockets): does it show, go full screen, take controller input, vsync? Decide which one the product uses and what it costs in the compositor.
3. **Q3, Proton.** Can a Steam Linux Runtime (pressure-vessel) that a packager bundles start inside the sandbox, with or without the sub-sandbox portal? (RuyaOS ships none; this only decides whether the guide calls Proton packages supported.)
4. **Resource and sandbox behaviour:** memory/task limits on the running scope, what a package-supplied environment can break, whether `--allow=multiarch` is needed for 32-bit games on Wine's WoW64 mode.
5. Write the answers into spec 05 (§6.4, §7.1, §16), amend ADR-014 if the fallback (bubblewrap directly) is needed, and edit T-230 to T-244 where the answers change their scope.

## Out of scope
- Any code in `services/` or `shell/`, the `Play1` contract, the runner packs (T-244), emulators.

## Acceptance criteria
- [ ] Each of Q1 to Q3 has a written answer in spec 05 with the commands and numbers that produced it (script output kept in the Outcome).
- [ ] The decision "import as Flatpak" or "bubblewrap fallback" is stated, with the owner-visible consequences, in ADR-014.
- [ ] `scripts/spikes/play/` has the scripts and a README, re-runnable on the VM.
- [ ] Child task files are edited where needed (or the Outcome says none needed).

## Verification
VM runs only (`docs/dev-setup.md`), one image build; end with `scripts\free-space.ps1`.

## Outcome
_Filled in by the implementer._
