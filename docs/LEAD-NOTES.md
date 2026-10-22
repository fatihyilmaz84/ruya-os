# Lead notes (handoff between lead sessions)

The procedure is in [`LEAD.md`](LEAD.md). **Rewrite this file at the end of every lead session**; keep it under about a page. History lives in the STATUS session log and git.

## Review range

- **Last reviewed commit: `9ca4b25`** (2026-10-22; builder tasks T-101–T-105, T-108 reviewed).
- **Next lead reviews:** `git log --oneline 9ca4b25..HEAD`. At handoff that was:
  - 8637579 (planning by Sonnet);
  - 93391d8 T-115;
  - fc76d7f (image boot work, by the lead; self-reviewed only);
  - ac1650d T-116;
  - 22e8c4a T-106;
  - 37e9711 (docs: GitHub remote);
  - 438ad9d T-117;
  - de6112e (planning by Sonnet).
- Last VM verification: 2026-10-22 on image 0.0.3/0.0.4 (boot, update, manual and automatic rollback). Everything image- or service-facing merged since then is **not** VM-verified.

## Concerns (ranked)

1. **ADR-002 (compositor) is still open, and it is the largest architecture risk.** The overlay over running apps, app switching and focus control depend on it. A *functional* spike is now possible in the VM (software rendering): shell as a QtWaylandCompositor hosting a client app, with a Guide overlay above it. Performance needs hardware later. **Suggest: create it as an `Owner: lead` task and do it in an early lead session.**
2. **Integration lags behind UI.** Most features run only against mocks. T-120 (Profiles and first-boot setup over the real bus in the VM) is the first real integration. Review it closely, and consider making "verified in VM" an acceptance criterion for every service-facing task.
3. **Two planning sessions were run by Sonnet** (8637579, de6112e). Check their tasks against the quality bar in `PLANNING.md` (observable criteria, reference patterns, sizes, no frozen contracts).
4. **The repo is public on GitHub** (since 2026-10-23). Run a secret scan over the whole history: `image/bib/config.toml` (dev SSH key) must never have been committed, and no keys or tokens may appear anywhere. Report the result to the owner.
5. **CI has never been green end to end** (T-122). Until it is, the owner's pushes aren't protected by CI.
6. **Image size is 4.7 GB.** Update sizes and chunking need a plan before any release (Inbox history, spec 01 §4).
7. **Real hardware (B-002) is untouched.** A dev ISO exists (`output/bootiso/install.iso`; it contains the dev SSH key, so it's for test machines only). Ask the owner whether a spare PC is available.

## First things the next lead should do

1. Steps 1–3 of `LEAD.md` over the range above (7 commits).
2. Secret scan (concern 4).
3. Rebuild the image from HEAD and run the smoke test (T-106 added a Setup screen that the VM shows on an empty profile store; does it render and accept keys over the real bus?).
4. Plan: is ADR-002 a lead task? Is T-120's scope right?

## Quality signals (one row per lead session)

| Date | Range reviewed | Tasks | Findings (fixed / filed) | `dev.ps1 test` | VM |
|---|---|---|---|---|---|
| 2026-10-22 | 91c4b89..ac93198 | T-101 | 0 / 1 (page host can't nest → T-111 hint) | 23 + 2 skipped | — |
| 2026-10-22 | ..ffd79bf | T-102 | 0 / 2 (Inbox) | 30 + 3 skipped | — |
| 2026-10-22 | ..b75bf66 | T-108, T-103, T-104, T-105 | 3 / 1 (offscreen gate, contract rule, planning lessons / probe → T-115) | 77 + 7 skipped | — |
| 2026-10-22 | image work | B-001, B-008 | 9 fixed (see dev-setup problem log) | 77 + 7 skipped | boot, update, rollback, greenboot ✅ |
