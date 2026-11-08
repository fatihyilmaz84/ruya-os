# T-350 - lint-dev-docs: every public API element is documented, every sample builds

Status: todo · Phase: 7 · Depends: — · Area: scripts, ci, docs · Size: S · Owner: builder · Developer surface: internal

## Goal
A public D-Bus method, signal or property cannot reach `main` undocumented, and a sample the guide points to cannot rot. Today `scripts/lint-dev-docs.ps1` checks links, code blocks, the `sample:` C blocks and the Sources footer, but knows nothing about `api/dbus/*.xml` and never builds a sample (ADR-022, `docs/developers/api-surface.md`).

## Read first
- `docs/developers/api-surface.md` ("How a public thing is made", the XML tag), ADR-022 in `docs/specs/00-overview.md`
- `scripts/lint-dev-docs.ps1` (the whole file) and the self-check fixtures in `scripts/dev.ps1` (around the `docs` command: each rule has a "rejected" and an "accepted" case)
- `samples/hello-game/Makefile` (`make test` needs no SDL), `.github/workflows/ci.yml` (the docs step)

## Scope
1. **Public elements.** Read every `api/dbus/*.xml`. A `method`, `signal` or `property` with `<annotation name="org.ruyaos.Stability" value="..."/>` is public. Fail when: the value is not `experimental`, `stable` or `deprecated`; `org.ruyaos.Since` is missing or not an integer. The tag is per element (a tag on the interface is ignored), so adding a method to a public interface is a deliberate act.
2. **Coverage.** The string `<Interface>.<Member>` (for example `org.ruyaos.Platform1.Achievements.Unlock`) must appear in a code span in some chapter of `docs/developers/` other than `api-surface.md`. The message names the element and the XML file.
3. **Samples.** A new switch `-Samples` runs `make -C samples/<name> test` for every `samples/*/` that has a Makefile; failing tests or a missing compiler are findings. Without the switch (`dev.ps1 docs` on Windows) the lint prints one visible line `samples not built (use -Samples)` and stays green; the CI step passes `-Samples`. A sample directory without a Makefile is allowed (data-only samples such as a sound theme).
4. **Self-check fixtures in `dev.ps1`:** an XML element tagged and documented (accepted); tagged and not documented (rejected, names the element); a bad Stability value (rejected); a missing `Since` (rejected); an untagged element (ignored, private).
5. Update the header comment of the lint, `docs/dev-setup.md` if a command changed, and the "Sources" line of `api-surface.md` if the rules text changes.

## Out of scope
- Checking that the sample uses only the public surface (a reviewer's job, `ruya-api-reviewer`).
- Tagging any existing XML element: no element is public yet (T-352 and the capability tasks do that).

## Acceptance criteria
- [ ] The fixtures of Scope 4 pass in `.\scripts\dev.ps1 test` (they fail when the matching rule in the lint is reverted: `revert-check.ps1`).
- [ ] `.\scripts\lint-dev-docs.ps1` on the real repo stays green (no public element exists yet).
- [ ] `-Samples` on Linux CI runs `samples/hello-game` `make test`; on the Windows host the lint prints the visible "not built" line.
- [ ] `.\scripts\dev.ps1 test` ends with `ALL GREEN`.

## Verification
```powershell
.\scripts\lint-dev-docs.ps1
.\scripts\dev.ps1 test
```

## Docs to update
- The lint's header comment; `docs/developers/README.md` last paragraph (what the lint checks); `docs/dev-setup.md` if needed.

## Hints
- Parse the XML with `System.Xml.XmlDocument`; the interface name is the `name` attribute of `node/interface`.
- Keep the lint's PowerShell 5.1 compatibility (no `&&`, no ternary).

## Outcome
_Filled in by the implementer. First line: `Verified: host | vm | unverified | hw`. Then: what was built, files, deviations, follow-ups._
