# T-297 — Lint, script and docs hygiene: self-check fixtures, hashed download, overlap check, a QML pitfall note

Status: todo · Phase: 2 · Depends: — · Area: scripts (lint-dev-docs, subset-icons, check-font-coverage), docs (developers, PATTERNS) · Size: S · Owner: builder

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
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw` (say what ran where). Then: what was built, files, deviations, follow-ups (each also an Inbox line)._
