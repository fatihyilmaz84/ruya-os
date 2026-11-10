# T-417 - AI entry points: `llms.txt`, a generated `llms-full.txt`, component and API catalogues, `AGENTS.md` for apps

Status: todo · Phase: 7 · Depends: T-416, T-251, T-252 · Area: docs/developers, scripts (generators and a sync lint), the app template · Size: S · Owner: builder · Developer surface: public-format

**Plan audit 2026-11-10 (lead; where this differs from the text below, this wins):** The API catalogue is T-350's `apis.json`, not a new extraction. Needs more than one criterion line.

## Goal
An AI agent pointed at the console's developer docs finds one short entry file, a single generated file with all stable docs, machine-readable catalogues of APIs and RuyaKit components, and an `AGENTS.md` in every new app that tells it how to build, run and validate.

## Read first
- ADR-031, `docs/developers/README.md`, `docs/specs/04-design-system.md` §5 (components), RuyaKit (T-251) `qmltypes`, T-252 (template), the proposal `docs/archive/research/ai-first-developer-platform-proposal.md` §5, §9.2

## Scope
1. `docs/developers/llms.txt` (hand-written, short: what Ruya is, where things are, the `ruya` commands) and `llms-full.txt` generated from the stable chapters (experimental ones marked).
2. `catalog/apis.json` and `catalog/components.json` generated from the XML and from 04 plus RuyaKit's `qmltypes` (properties, focus and controller behaviour, accessibility); `ruya sdk components` reads them.
3. The template's `AGENTS.md` (build, run, validate commands; HIG rules; what is forbidden).
4. A lint fails when a generated file is out of date.

## Acceptance criteria
- [ ] The sync lint is red when a chapter or an XML element changes without regenerating; `ruya-devdocs-auditor` run with only `llms.txt` as its start reports the path to a working sample; `dev.ps1 test` ALL GREEN.

## Outcome
_Filled in by the implementer._
