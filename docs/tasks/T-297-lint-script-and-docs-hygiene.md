# T-297 — Lint, script and docs hygiene: self-check fixtures, hashed download, overlap check, a QML pitfall note

Status: done · Phase: 2 · Depends: — · Area: scripts (lint-dev-docs, subset-icons, check-font-coverage), docs (developers, PATTERNS) · Size: S · Owner: builder

## Goal
Five small gaps in the guard rails that review rounds found are closed, so the lints fail when they should and the one unchecked download is checked.

## Read first
- `scripts/lint-dev-docs.ps1` (the `/* sample: <path> */` C-block rule, ~line 189) and its self-check in `scripts/dev.ps1`; `docs/developers/appstream-metadata.md`; the sample app and its metainfo (`samples/`, see T-214 Outcome)
- `scripts/subset-icons.sh` (`skia-pathops==0.9.2`, venv + pip, ~line 37), `scripts/check-font-coverage.py`; `shell/PATTERNS.md`
- STATUS-parked.md "Inbox triage 2026-11-07", bullets T-297

## Scope
1. **Self-check fixture** for the `/* sample: <path> */` C-block rule: `dev.ps1`'s lint self-check gets one passing and one failing block (a block whose code differs from the sample file) so the rule is proven to fail.
2. **AppStream example vs the sample's metainfo:** `lint-dev-docs.ps1` compares the XML example in `appstream-metadata.md` with the sample's real metainfo (same element names and required attributes, not identical text) and fails on a drift.
3. **Hashed download:** `subset-icons.sh` installs `skia-pathops` with `--require-hashes` from a pinned requirements file (hash of the wheel(s) it needs on Fedora's Python; WSL only, no change when run on other hosts).
4. **Overlap check:** `check-font-coverage.py` also catches any overlapping contours in the icon cuts (not only identical coincident ones): flag a glyph whose contours intersect with the same winding (an even-odd versus non-zero fill difference computed in pure Python on flattened outlines), with a fixture TTF-free unit test of the geometry helper.
5. **PATTERNS note:** `anchors.verticalCenterOffset: (cond ? a : b) * u` did not update offscreen (T-260); write the pitfall and the working form (a property binding, or an `Item` with explicit `y`) into `shell/PATTERNS.md`, and extend `scripts/lint-qml-members.ps1` only if a one-line pattern catches it without false positives.

## Out of scope
- A shared `RuyaTestCase` guard against NaN waits (only if a fourth vacuous wait appears), new lints for other pitfalls, upgrading Python or fonts.

## Acceptance criteria
- [ ] `dev.ps1` self-check output lists the new fixture pair and fails when the rule is disabled (revert check noted).
- [ ] `scripts\lint-dev-docs.ps1` fails when an element is renamed in the example (shown once in the Outcome) and passes on the tree.
- [ ] `subset-icons.sh` runs `pip install --require-hashes -r` a committed file (grep in the Outcome; the WSL run is the lead's: `Verified: host (vm pending: subset-icons.sh in WSL)`).
- [ ] `check-font-coverage.py` has a self-test of the overlap helper (two overlapping squares flagged, two disjoint not) that runs in `dev.ps1 test`, and still passes on the shipped cuts.
- [ ] `shell/PATTERNS.md` has the pitfall entry.
- [ ] `.\scripts\dev.ps1 test` ALL GREEN; `scripts\lint-text.ps1` exits 0.

## Verification
```powershell
.\scripts\dev.ps1 test
```

## Docs to update
- `docs/developers/` only if the AppStream example changes; `docs/dev-setup.md` if the subset command changes.

## Hints
- Run Python with `-I` and `encoding="utf-8"` (root CLAUDE.md, pitfalls). Paths with backslashes only through Write/Edit.
- No overlap with open tasks.

## Outcome
Verified: host (vm pending: subset-icons.sh in WSL)

**Built**
1. **C-block fixtures.** `dev.ps1` developer-guide self-check has two new cases: "a C block that is the sample's code: accepted" and "a C block whose code differs from the sample file: rejected" (the fixture folder carries a `s/game.c`; `Test-DevDocs` now takes an optional `files` map per case). Revert check: with `if ($first -match '^\s*/\*\s*sample:` changed to `if ($false -and ...` in `lint-dev-docs.ps1`, the rejected case reports `FAILED` (run by hand, file restored).
2. **AppStream example vs the sample's metainfo.** `lint-dev-docs.ps1`: an `xml` fence whose root is `<component>` and which has a `` `samples/.../*.metainfo.xml` `` path in backticks in the three lines before it is compared with that file (`Get-XmlShape`: every element's path plus its attribute names, and the values of `id`, `type`, `key`; multiset; order, text and other values ignored). The real chapter passes; shown once: with `<summary>` renamed to `<tagline>` in the example the lint exits 1 with `the example differs from samples/hello-game/data/org.ruyaos.HelloGame.metainfo.xml: /component/summary[] appears 0 time(s) in the example and 1 in the file` (and the `tagline` line). Three self-check cases (other text accepted, renamed element rejected, dropped `date` attribute rejected); revert check: `if ($na -ne $nc) {` changed to `if ($false) {` makes both rejected cases `FAILED`.
3. **Hashed download.** New `scripts/subset-icons-requirements.txt` (`skia-pathops==0.9.2` with the SHA-256 of the manylinux x86_64 and aarch64 abi3 wheels, from PyPI's JSON); `subset-icons.sh` runs `venv/bin/pip install -q --only-binary=:all: --require-hashes -r "$repo/scripts/subset-icons-requirements.txt"` (the `PATHOPS` variable is gone). On the host I ran `pip download --require-hashes` with `--platform manylinux2014_x86_64 --python-version 3.14` against the file: the hash matched. The WSL run of the whole script is the lead's (**vm pending: subset-icons.sh in WSL**; nothing in the image changed).
4. **Overlap check.** `check-font-coverage.py`: the glyph reader is now `glyph_contours()` (a generator, points with on-curve flags), `coincident_contours()` builds on it, and `overlapping_glyph_contours()` flattens the quadratic outlines (8 steps) and flags a pair of contours of one glyph with the same winding whose edges cross, or where a boundary point of one lies inside the other while the rest of the glyph winds the same way around it (non-zero versus even-odd differ there). Opposite winding (holes), touching shapes, an island inside a hole and zero-area slivers are not flagged (the shipped filled cut has a zero-area contour in glyph 2; it draws nothing). `self_test()` (hand-made outlines, no TTF: overlapping squares, disjoint, shared edge or corner, nested, hole, ring with island, plus of bars, off-centre long bars, circle and square, zero-area spike) runs first in every normal run (so in CI) and alone with `--self-test`; `dev.ps1 test` records it as "font coverage self-test (overlap helper: overlapping squares flagged, disjoint ones not)". The shipped cuts still pass (`check-font-coverage: ok`). Revert checks: `_cross` forced to False fails "two long bars that cross off-centre"; the zero-area guard removed fails "a zero-area spike inside a square". Not proven on a real un-merged cut (the variable font is not on this machine).
5. **PATTERNS note.** `shell/PATTERNS.md` has "Pitfall: a ternary inside a product in an anchor offset (T-260, T-297)" with the working forms. `lint-qml-members.ps1` now rejects `(vertical|horizontal)CenterOffset: (cond ? a : b) * x` on one line (no false positive in the tree: the only ternary offset, `ProfilePicker.qml`, uses the working form); the `dev.ps1` self-check "QML member lint self-check (rejects a ternary inside a product in an anchor offset, accepts the working form)" fails when the check is disabled (revert check: `if ($offsetRe.IsMatch($line))` changed to `if ($false)`).

**Files:** `scripts/lint-dev-docs.ps1`, `scripts/lint-qml-members.ps1`, `scripts/check-font-coverage.py`, `scripts/subset-icons.sh`, `scripts/subset-icons-requirements.txt` (new), `scripts/dev.ps1`, `shell/PATTERNS.md`, `docs/dev-setup.md` (subset command and the new check).

**Deviations:** none. The AppStream example has no marker of its own: the lint finds the sample through the backticked path in the prose before the fence (the chapter already had it), so the example text did not change.
